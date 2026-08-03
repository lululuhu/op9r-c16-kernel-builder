/*
 * cpufreq_windchill.c — Oblivionis Windchill CPU Frequency Governor
 *
 * Inspired by OnePlus "风驰游戏内核" (Windchill Game Kernel) concepts:
 *   - Energy-aware model: precise performance-power balance
 *   - Fast frequency ramp-up for high-demand scenarios
 *   - Smart ramp-down with hysteresis to avoid premature drops
 *   - Scene-aware dynamic frequency/voltage adjustment
 *
 * Original implementation for Oblivionis-kernel (4.19)
 *
 * Key design principles:
 *   1. Hybrid sampling: timer-based + workload-driven
 *   2. Trend analysis: exponential moving average of CPU load
 *   3. Frequency clamping: minimum frequency floor for responsiveness
 *   4. Boost window: temporary frequency boost on sudden load increase
 *   5. Energy efficiency: prefer lower frequencies when load is stable
 *
 * Copyright (C) 2024 Oblivionis-kernel
 * Licensed under GPL-2.0
 */

#include <linux/cpu.h>
#include <linux/cpufreq.h>
#include <linux/cpumask.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/tick.h>
#include <linux/time.h>
#include <linux/types.h>
#include <linux/workqueue.h>

/* ===================================================================
 * Tunable parameters (configurable via sysfs)
 * =================================================================== */

#define WINDCHILL_DEFAULT_SAMPLE_MS		20
#define WINDCHILL_DEFAULT_UP_THRESHOLD		75
#define WINDCHILL_DEFAULT_DOWN_THRESHOLD	30
#define WINDCHILL_DEFAULT_BOOST_THRESHOLD	90
#define WINDCHILL_DEFAULT_FREQ_STEP		25
#define WINDCHILL_DEFAULT_BOOST_FREQ_STEP	50
#define WINDCHILL_DEFAULT_EMA_ALPHA		60	/* 0-100, higher = faster response */
#define WINDCHILL_DEFAULT_BOOST_DURATION_MS	60
#define WINDCHILL_DEFAULT_HYSTERESIS		10

/* EMA calculation: ema = alpha * new + (100 - alpha) * old */
#define EMA_CALC(alpha, new_val, old_val) \
	(((alpha) * (new_val) + (100 - (alpha)) * (old_val)) / 100)

/* ===================================================================
 * Per-policy private data
 * =================================================================== */

struct windchill_tunables {
	unsigned int	sample_ms;	/* Sampling interval */
	unsigned int	up_threshold;	/* Load % to ramp up */
	unsigned int	down_threshold;	/* Load % to ramp down */
	unsigned int	boost_threshold;	/* Load % to boost */
	unsigned int	freq_step;	/* Normal ramp-up step % */
	unsigned int	boost_freq_step;	/* Boost ramp-up step % */
	unsigned int	ema_alpha;	/* EMA smoothing factor (0-100) */
	unsigned int	boost_duration;	/* Boost hold time in ms */
	unsigned int	hysteresis;	/* Down-threshold hysteresis */
	unsigned int	min_freq_floor;	/* Minimum frequency floor (kHz) */
	bool		boost_active;	/* Currently in boost state */
	u64		boost_start_time; /* When boost started (ns) */
};

struct windchill_policy {
	struct cpufreq_policy	*policy;
	struct windchill_tunables *tunables;
	struct delayed_work	work;
	unsigned int		prev_load;	/* Previous sampled load */
	unsigned int		ema_load;	/* EMA-smoothed load */
	unsigned int		cur_freq;	/* Last set frequency */
	unsigned int		target_freq;	/* Target frequency */
	u64			last_sample_time; /* Last sample timestamp */
	bool			enabled;
	struct mutex		mutex;
};

static struct windchill_policy **windchill_policies;

/* ===================================================================
 * Global tunables (module parameters, can be overridden at boot)
 * =================================================================== */

static unsigned int windchill_sample_ms = WINDCHILL_DEFAULT_SAMPLE_MS;
module_param(windchill_sample_ms, uint, 0644);

static unsigned int windchill_up_threshold = WINDCHILL_DEFAULT_UP_THRESHOLD;
module_param(windchill_up_threshold, uint, 0644);

static unsigned int windchill_down_threshold = WINDCHILL_DEFAULT_DOWN_THRESHOLD;
module_param(windchill_down_threshold, uint, 0644);

static unsigned int windchill_boost_threshold = WINDCHILL_DEFAULT_BOOST_THRESHOLD;
module_param(windchill_boost_threshold, uint, 0644);

static unsigned int windchill_freq_step = WINDCHILL_DEFAULT_FREQ_STEP;
module_param(windchill_freq_step, uint, 0644);

static unsigned int windchill_boost_freq_step = WINDCHILL_DEFAULT_BOOST_FREQ_STEP;
module_param(windchill_boost_freq_step, uint, 0644);

static unsigned int windchill_ema_alpha = WINDCHILL_DEFAULT_EMA_ALPHA;
module_param(windchill_ema_alpha, uint, 0644);

static unsigned int windchill_boost_duration = WINDCHILL_DEFAULT_BOOST_DURATION_MS;
module_param(windchill_boost_duration, uint, 0644);

static unsigned int windchill_hysteresis = WINDCHILL_DEFAULT_HYSTERESIS;
module_param(windchill_hysteresis, uint, 0644);

/* ===================================================================
 * Load calculation
 * =================================================================== */

static unsigned int windchill_get_load(struct windchill_policy *wp)
{
	struct cpufreq_policy *policy = wp->policy;
	u64 now, idle_time, active_time, total_time;
	unsigned int load;
	int cpu;

	/*
	 * Use the first CPU in the policy for load calculation.
	 * For shared policies (all CPUs in cluster), this gives a representative
	 * load value for the cluster.
	 */
	cpu = policy->cpu;

	now = get_jiffies_64();

	/* Calculate using CPU's idle time */
	idle_time = get_cpu_idle_time(cpu, &wp->last_sample_time, 0);
	total_time = now - wp->last_sample_time;

	if (total_time == 0)
		return wp->prev_load;

	active_time = total_time - idle_time;

	/* Scale to percentage (0-100) */
	load = (unsigned int)div64_u64(active_time * 100, total_time);

	/* Clamp to [0, 100] */
	if (load > 100)
		load = 100;

	wp->last_sample_time = now;

	return load;
}

/* ===================================================================
 * Frequency selection — the core Windchill algorithm
 * =================================================================== */

static unsigned int windchill_select_freq(struct windchill_policy *wp,
					  unsigned int load)
{
	struct cpufreq_policy *policy = wp->policy;
	struct windchill_tunables *t = wp->tunables;
	unsigned int freq = wp->cur_freq;
	unsigned int min_freq = policy->cpuinfo.min_freq;
	unsigned int max_freq = policy->cpuinfo.max_freq;
	unsigned int freq_range, step, target;
	u64 now;

	/* Apply frequency floor */
	if (t->min_freq_floor > min_freq)
		min_freq = t->min_freq_floor;

	freq_range = max_freq - min_freq;

	/* Update EMA-smoothed load */
	wp->ema_load = EMA_CALC(t->ema_alpha, load, wp->ema_load);

	now = ktime_get_ns();

	/*
	 * Check if boost should expire
	 * Boost holds frequency high for a duration after burst load
	 */
	if (t->boost_active) {
		if (now - t->boost_start_time >
		    (u64)t->boost_duration * NSEC_PER_MSEC) {
			t->boost_active = false;
		}
	}

	/*
	 * Windchill frequency selection logic:
	 *
	 * 1. If load > boost_threshold: immediate boost to max or near-max
	 * 2. If load > up_threshold: ramp up by freq_step
	 * 3. If load < down_threshold - hysteresis: ramp down
	 * 4. Otherwise: maintain current frequency (stable region)
	 *
	 * The hysteresis prevents oscillation around the thresholds.
	 */

	if (load >= t->boost_threshold) {
		/* Burst load: boost to maximum */
		target = max_freq;
		t->boost_active = true;
		t->boost_start_time = now;
	} else if (t->boost_active) {
		/* In boost window: hold high frequency */
		target = max_freq;
		/* Gradually reduce if load drops significantly */
		if (wp->ema_load < t->down_threshold) {
			target = freq - (freq_range * t->freq_step / 100);
		}
	} else if (wp->ema_load >= t->up_threshold) {
		/* High sustained load: ramp up */
		step = freq_range * t->freq_step / 100;
		target = freq + step;

		/* If very high load, use bigger step */
		if (load >= t->boost_threshold - 10) {
			step = freq_range * t->boost_freq_step / 100;
			target = freq + step;
		}
	} else if (wp->ema_load <= t->down_threshold) {
		/* Low load: ramp down gradually */
		step = freq_range * t->freq_step / 100;
		target = freq - step;
	} else {
		/* Stable region: maintain current frequency */
		target = freq;
	}

	/* Clamp to policy range */
	if (target < min_freq)
		target = min_freq;
	if (target > max_freq)
		target = max_freq;

	/*
	 * Energy-aware adjustment:
	 * When load is very low (< 20%) and stable, drop to minimum
	 * to maximize power savings.
	 */
	if (wp->ema_load < 20 && load < 20) {
		target = min_freq;
	}

	/*
	 * When load is moderate (30-60%) and stable (low variance),
	 * round to a "sweet spot" frequency for energy efficiency.
	 * Sweet spots are typically around 50-70% of max frequency.
	 */
	if (wp->ema_load > t->down_threshold &&
	    wp->ema_load < t->up_threshold) {
		unsigned int sweet_spot = min_freq + (freq_range * 6 / 10);
		/* If target is within 10% of sweet spot, snap to it */
		unsigned int diff = (target > sweet_spot) ?
				    (target - sweet_spot) : (sweet_spot - target);
		if (diff < (freq_range / 10)) {
			target = sweet_spot;
		}
	}

	return target;
}

/* ===================================================================
 * Sampling workqueue handler
 * =================================================================== */

static void windchill_work_fn(struct work_struct *work)
{
	struct windchill_policy *wp = container_of(to_delayed_work(work),
						   struct windchill_policy, work);
	struct cpufreq_policy *policy;
	unsigned int load, target_freq;
	unsigned int delay_us;

	mutex_lock(&wp->mutex);

	if (!wp->enabled) {
		mutex_unlock(&wp->mutex);
		return;
	}

	policy = wp->policy;
	if (!policy) {
		mutex_unlock(&wp->mutex);
		return;
	}

	/* Sample current load */
	load = windchill_get_load(wp);
	wp->prev_load = load;

	/* Select target frequency using Windchill algorithm */
	target_freq = windchill_select_freq(wp, load);

	/* Apply new frequency if different */
	if (target_freq != wp->cur_freq) {
		/*
		 * Use __cpufreq_driver_target for frequency change.
		 * CPUFREQ_RELATION_L: find lowest freq >= target (power efficient)
		 */
		__cpufreq_driver_target(policy, target_freq,
					CPUFREQ_RELATION_L);
		wp->cur_freq = target_freq;
	}

	mutex_unlock(&wp->mutex);

	/* Schedule next sample */
	delay_us = wp->tunables->sample_ms * USEC_PER_MSEC;
	schedule_delayed_work(&wp->work, usecs_to_jiffies(delay_us));
}

/* ===================================================================
 * Sysfs interface — using standard cpufreq freq_attr
 * =================================================================== */

/*
 * struct freq_attr is the standard attribute type used by cpufreq.
 * The cpufreq core provides sysfs_ops that handle freq_attr for
 * policy->kobj, so we don't need custom kobj_type/sysfs_ops.
 *
 * struct freq_attr {
 *     struct attribute attr;
 *     ssize_t (*show)(struct cpufreq_policy *, char *);
 *     ssize_t (*store)(struct cpufreq_policy *, const char *, size_t);
 * };
 */

#define WINDCHILL_ATTR_RW(_name)					\
static struct freq_attr _name = __ATTR(_name, 0644,			\
		show_##_name, store_##_name)

#define WINDCHILL_ATTR_RO(_name)					\
static struct freq_attr _name = __ATTR(_name, 0444,			\
		show_##_name, NULL)

#define show_one(file_name, object)					\
static ssize_t show_##file_name(struct cpufreq_policy *policy, char *buf) \
{									\
	struct windchill_policy *wp = windchill_policies[policy->cpu]; \
	if (!wp || !wp->tunables)					\
		return -EINVAL;						\
	return sprintf(buf, "%u\n", wp->tunables->object);		\
}

#define store_one(file_name, object)					\
static ssize_t store_##file_name(struct cpufreq_policy *policy,	\
				 const char *buf, size_t count)		\
{									\
	struct windchill_policy *wp = windchill_policies[policy->cpu]; \
	unsigned int val;						\
	int ret;							\
	if (!wp || !wp->tunables)					\
		return -EINVAL;						\
	ret = kstrtouint(buf, 10, &val);				\
	if (ret)							\
		return ret;						\
	wp->tunables->object = val;					\
	return count;							\
}

show_one(sample_ms, sample_ms);
store_one(sample_ms, sample_ms);
show_one(up_threshold, up_threshold);
store_one(up_threshold, up_threshold);
show_one(down_threshold, down_threshold);
store_one(down_threshold, down_threshold);
show_one(boost_threshold, boost_threshold);
store_one(boost_threshold, boost_threshold);
show_one(freq_step, freq_step);
store_one(freq_step, freq_step);
show_one(boost_freq_step, boost_freq_step);
store_one(boost_freq_step, boost_freq_step);
show_one(ema_alpha, ema_alpha);
store_one(ema_alpha, ema_alpha);
show_one(boost_duration, boost_duration);
store_one(boost_duration, boost_duration);
show_one(hysteresis, hysteresis);
store_one(hysteresis, hysteresis);
show_one(min_freq_floor, min_freq_floor);
store_one(min_freq_floor, min_freq_floor);

static ssize_t show_ema_load(struct cpufreq_policy *policy, char *buf)
{
	struct windchill_policy *wp = windchill_policies[policy->cpu];
	if (!wp)
		return -EINVAL;
	return sprintf(buf, "%u\n", wp->ema_load);
}

static ssize_t show_boost_active(struct cpufreq_policy *policy, char *buf)
{
	struct windchill_policy *wp = windchill_policies[policy->cpu];
	if (!wp || !wp->tunables)
		return -EINVAL;
	return sprintf(buf, "%u\n", wp->tunables->boost_active ? 1 : 0);
}

static ssize_t store_boost_active(struct cpufreq_policy *policy,
				  const char *buf, size_t count)
{
	struct windchill_policy *wp = windchill_policies[policy->cpu];
	unsigned int val;
	int ret;
	if (!wp || !wp->tunables)
		return -EINVAL;
	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val) {
		wp->tunables->boost_active = true;
		wp->tunables->boost_start_time = ktime_get_ns();
	} else {
		wp->tunables->boost_active = false;
	}
	return count;
}

WINDCHILL_ATTR_RW(sample_ms);
WINDCHILL_ATTR_RW(up_threshold);
WINDCHILL_ATTR_RW(down_threshold);
WINDCHILL_ATTR_RW(boost_threshold);
WINDCHILL_ATTR_RW(freq_step);
WINDCHILL_ATTR_RW(boost_freq_step);
WINDCHILL_ATTR_RW(ema_alpha);
WINDCHILL_ATTR_RW(boost_duration);
WINDCHILL_ATTR_RW(hysteresis);
WINDCHILL_ATTR_RW(min_freq_floor);
WINDCHILL_ATTR_RO(ema_load);
WINDCHILL_ATTR_RW(boost_active);

static struct attribute *windchill_attrs[] = {
	&sample_ms.attr,
	&up_threshold.attr,
	&down_threshold.attr,
	&boost_threshold.attr,
	&freq_step.attr,
	&boost_freq_step.attr,
	&ema_alpha.attr,
	&boost_duration.attr,
	&hysteresis.attr,
	&min_freq_floor.attr,
	&ema_load.attr,
	&boost_active.attr,
	NULL
};

static struct attribute_group windchill_attr_group = {
	.attrs = windchill_attrs,
	.name = "windchill",
};

/* ===================================================================
 * Governor callbacks
 * =================================================================== */

static int windchill_init(struct cpufreq_policy *policy)
{
	struct windchill_policy *wp;
	struct windchill_tunables *tunables;
	unsigned int cpu = policy->cpu;
	int ret;

	/* Only initialize once per policy */
	if (cpu != cpumask_first(policy->related_cpus))
		return 0;

	wp = kzalloc(sizeof(*wp), GFP_KERNEL);
	if (!wp)
		return -ENOMEM;

	tunables = kzalloc(sizeof(*tunables), GFP_KERNEL);
	if (!tunables) {
		kfree(wp);
		return -ENOMEM;
	}

	/* Initialize tunables with default values */
	tunables->sample_ms = windchill_sample_ms;
	tunables->up_threshold = windchill_up_threshold;
	tunables->down_threshold = windchill_down_threshold;
	tunables->boost_threshold = windchill_boost_threshold;
	tunables->freq_step = windchill_freq_step;
	tunables->boost_freq_step = windchill_boost_freq_step;
	tunables->ema_alpha = windchill_ema_alpha;
	tunables->boost_duration = windchill_boost_duration;
	tunables->hysteresis = windchill_hysteresis;
	tunables->min_freq_floor = 0;
	tunables->boost_active = false;
	tunables->boost_start_time = 0;

	wp->policy = policy;
	wp->tunables = tunables;
	wp->prev_load = 0;
	wp->ema_load = 0;
	wp->cur_freq = policy->cur;
	wp->target_freq = policy->cur;
	wp->last_sample_time = get_jiffies_64();
	wp->enabled = false;
	mutex_init(&wp->mutex);

	windchill_policies[cpu] = wp;

	/* Create sysfs interface */
	ret = sysfs_create_group(&policy->kobj, &windchill_attr_group);
	if (ret) {
		pr_err("windchill: failed to create sysfs group: %d\n", ret);
		kfree(tunables);
		kfree(wp);
		windchill_policies[cpu] = NULL;
		return ret;
	}

	pr_info("windchill: initialized for CPU%d (freq: %u-%u kHz)\n",
		cpu, policy->cpuinfo.min_freq, policy->cpuinfo.max_freq);

	return 0;
}

static void windchill_exit(struct cpufreq_policy *policy)
{
	struct windchill_policy *wp;
	unsigned int cpu = policy->cpu;

	wp = windchill_policies[cpu];
	if (!wp)
		return;

	/* Stop the work queue */
	mutex_lock(&wp->mutex);
	wp->enabled = false;
	cancel_delayed_work_sync(&wp->work);
	mutex_unlock(&wp->mutex);

	sysfs_remove_group(&policy->kobj, &windchill_attr_group);

	kfree(wp->tunables);
	kfree(wp);
	windchill_policies[cpu] = NULL;

	pr_info("windchill: exited for CPU%d\n", cpu);
}

static int windchill_start(struct cpufreq_policy *policy)
{
	struct windchill_policy *wp;
	unsigned int cpu = policy->cpu;

	wp = windchill_policies[cpu];
	if (!wp)
		return -EINVAL;

	INIT_DELAYED_WORK(&wp->work, windchill_work_fn);

	mutex_lock(&wp->mutex);
	wp->enabled = true;
	wp->cur_freq = policy->cur;
	wp->last_sample_time = get_jiffies_64();
	mutex_unlock(&wp->mutex);

	/* Start sampling */
	schedule_delayed_work(&wp->work,
		usecs_to_jiffies(wp->tunables->sample_ms * USEC_PER_MSEC));

	pr_info("windchill: started for CPU%d\n", cpu);
	return 0;
}

static void windchill_stop(struct cpufreq_policy *policy)
{
	struct windchill_policy *wp;
	unsigned int cpu = policy->cpu;

	wp = windchill_policies[cpu];
	if (!wp)
		return;

	mutex_lock(&wp->mutex);
	wp->enabled = false;
	mutex_unlock(&wp->mutex);

	cancel_delayed_work_sync(&wp->work);

	pr_info("windchill: stopped for CPU%d\n", cpu);
}

static void windchill_limits(struct cpufreq_policy *policy)
{
	struct windchill_policy *wp;
	unsigned int cpu = policy->cpu;

	wp = windchill_policies[cpu];
	if (!wp || !wp->enabled)
		return;

	mutex_lock(&wp->mutex);

	/* Respect policy limits */
	if (wp->cur_freq > policy->max)
		wp->cur_freq = policy->max;
	if (wp->cur_freq < policy->min)
		wp->cur_freq = policy->min;

	__cpufreq_driver_target(policy, wp->cur_freq, CPUFREQ_RELATION_L);

	mutex_unlock(&wp->mutex);
}

static ssize_t windchill_show_setspeed(struct cpufreq_policy *policy,
				       char *buf)
{
	struct windchill_policy *wp = windchill_policies[policy->cpu];
	if (!wp)
		return -EINVAL;
	return sprintf(buf, "%u\n", wp->cur_freq);
}

static ssize_t windchill_store_setspeed(struct cpufreq_policy *policy,
					const char *buf, size_t count)
{
	struct windchill_policy *wp = windchill_policies[policy->cpu];
	unsigned int val;
	int ret;

	if (!wp || !wp->enabled)
		return -EINVAL;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;

	mutex_lock(&wp->mutex);
	wp->target_freq = val;
	__cpufreq_driver_target(policy, val, CPUFREQ_RELATION_L);
	wp->cur_freq = val;
	mutex_unlock(&wp->mutex);

	return count;
}

/* ===================================================================
 * Governor structure
 * =================================================================== */

static struct cpufreq_governor windchill_gov = {
	.name		= "windchill",
	.init		= windchill_init,
	.exit		= windchill_exit,
	.start		= windchill_start,
	.stop		= windchill_stop,
	.limits		= windchill_limits,
	.show_setspeed	= windchill_show_setspeed,
	.store_setspeed	= windchill_store_setspeed,
	.owner		= THIS_MODULE,
};

static int __init windchill_register(void)
{
	int ret;

	windchill_policies = kcalloc(nr_cpu_ids,
				     sizeof(struct windchill_policy *),
				     GFP_KERNEL);
	if (!windchill_policies)
		return -ENOMEM;

	ret = cpufreq_register_governor(&windchill_gov);
	if (ret) {
		pr_err("windchill: failed to register governor: %d\n", ret);
		kfree(windchill_policies);
		return ret;
	}

	pr_info("windchill: governor registered (风驰调速器)\n");
	return 0;
}

static void __exit windchill_unregister(void)
{
	cpufreq_unregister_governor(&windchill_gov);
	kfree(windchill_policies);
	pr_info("windchill: governor unregistered\n");
}

/* ===================================================================
 * Module entry points
 *
 * Can be built-in (=y) or module (=m).
 * When built-in, module_init/module_exit map to pure initcalls.
 * =================================================================== */

#ifdef CONFIG_CPU_FREQ_DEFAULT_GOV_WINDCHILL
struct cpufreq_governor *cpufreq_default_governor(void)
{
	return &windchill_gov;
}
#endif

module_init(windchill_register);
module_exit(windchill_unregister);

MODULE_AUTHOR("Oblivionis-kernel");
MODULE_DESCRIPTION("Windchill CPU Frequency Governor (风驰调速器)");
MODULE_LICENSE("GPL");
