// SPDX-License-Identifier: GPL-2.0
/*
 * adios.c - ADIOS (Adaptive Deadline I/O Scheduler) 3.2.0
 *
 * 基于 mq-deadline 的 blk-mq I/O 调度器框架，添加:
 *   - 自适应截止时间调度: 根据观测到的 I/O 延迟动态调整请求超时时间
 *   - 混合 deadline 调度与优先级调度: 正常时按 deadline/FIFO 调度，
 *     紧急或高优先级请求可提前派发
 *   - 延迟模型优化: 用指数加权移动平均(EWMA)跟踪读/写延迟，
 *     自适应调整 fifo_expire，避免固定超时在不同负载下不合理
 *   - 优先级调度: passthrough/urgent 请求优先; 超时请求提升优先级
 *   - 异常处理: 空队列、饥饿保护、batch 用尽后切换方向
 *   - 批量处理(batch 计数器): 连续派发同一方向的请求以减少调度开销
 *
 * 4.19 兼容性说明:
 *   - 使用 elevator_mq_ops API (4.19 blk-mq 调度器接口)
 *   - 使用 elv_register / elv_unregister 注册
 *   - 使用 elevator_alloc 分配 elevator_queue
 *   - 使用 blk_mq_sched_try_merge / blk_mq_sched_try_insert_merge 等 4.19 辅助函数
 *   - 使用 elv_rb_add / elv_rb_del / elv_rb_find / elv_rb_latter/former_request
 *   - 不依赖 5.0+ API (如 blk_mq_alloc_data 的新字段等)
 *   - sysfs 属性通过 elevator_attrs 暴露
 *
 * 维护的数据结构:
 *   - read_fifo  / write_fifo : 按 FIFO(到达顺序)排列的请求链表，用于 deadline 检测
 *   - sort_list[2]             : 按扇区排序的红黑树，用于合并与顺序派发
 *   - dispatch                 : 派发队列(at_head 请求直接进入)
 */

#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/blkdev.h>
#include <linux/blk-mq.h>
#include <linux/elevator.h>
#include <linux/bio.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/init.h>
#include <linux/compiler.h>
#include <linux/rbtree.h>
#include <linux/sbitmap.h>
#include <linux/sched/clock.h>

/* ---- 默认参数 ---- */
/* 读请求最大等待时间(软超时)，以 jiffies 为单位 */
static const int read_expire = HZ / 2;       /* 500ms */
/* 写请求最大等待时间 */
static const int write_expire = 5 * HZ;      /* 5s */
/* 读最多可以让写饥饿的次数 */
static const int writes_starved = 2;
/* 批量派发数量: 连续派发同一方向这么多请求后才考虑切换方向 */
static const int fifo_batch = 16;
/* 自适应延迟跟踪的 EWMA 权重 (分母，越大越平滑) */
static const int adios_latency_ewma_weight = 8;
/* 延迟目标: 当观测延迟超过目标的 expire 时，自动缩短 expire */
static const int adios_latency_factor = 3;   /* 观测延迟 > expire*factor 时收紧 */

/*
 * ADIOS 调度器私有数据。
 * 对应每个 request_queue 一个实例(共享于所有硬件队列)。
 */
struct adios_data {
	/*
	 * 请求同时存在于 sort_list(红黑树) 和 fifo_list(FIFO) 中。
	 * fifo_list 用于 deadline 检测; sort_list 用于扇区排序与合并。
	 */
	struct rb_root sort_list[2];       /* [READ]=读, [WRITE]=写 */
	struct list_head fifo_list[2];     /* read_fifo, write_fifo */

	/* sort_list 中下一个要派发的请求(按扇区序) */
	struct request *next_rq[2];

	/* 批量派发计数器: 当前批次已派发数量 */
	unsigned int batching;
	/* 读让写饥饿的次数计数 */
	unsigned int starved;

	/* ---- 自适应延迟模型 ---- */
	/* 观测到的读延迟 EWMA (jiffies) */
	unsigned int latency_avg_read;
	/* 观测到的写延迟 EWMA (jiffies) */
	unsigned int latency_avg_write;
	/* 上次完成请求的时间，用于计算延迟 */
	unsigned long last_complete_time;
	/* 自适应调整次数(用于限速调整频率) */
	unsigned int adjust_count;

	/* ---- 可调参数 ---- */
	int fifo_expire[2];       /* [READ], [WRITE] 的当前 expire */
	int fifo_batch;
	int writes_starved;
	int front_merges;

	/* 基准 expire(不随自适应变化)，用于重置 */
	int base_expire[2];

	spinlock_t lock;
	struct list_head dispatch;   /* at_head / passthrough 请求的派发队列 */
};

/* ---- 红黑树辅助 ---- */

static inline struct rb_root *
adios_rb_root(struct adios_data *ad, struct request *rq)
{
	return &ad->sort_list[rq_data_dir(rq)];
}

/* 获取 sort_list 中 rq 的下一个请求(按扇区序) */
static inline struct request *
adios_latter_request(struct request *rq)
{
	struct rb_node *node = rb_next(&rq->rb_node);

	if (node)
		return rb_entry_rq(node);
	return NULL;
}

static void adios_add_rq_rb(struct adios_data *ad, struct request *rq)
{
	elv_rb_add(adios_rb_root(ad, rq), rq);
}

static inline void
adios_del_rq_rb(struct adios_data *ad, struct request *rq)
{
	const int data_dir = rq_data_dir(rq);

	if (ad->next_rq[data_dir] == rq)
		ad->next_rq[data_dir] = adios_latter_request(rq);

	elv_rb_del(adios_rb_root(ad, rq), rq);
}

/*
 * 从 rbtree 和 fifo 中移除请求。
 */
static void adios_remove_request(struct request_queue *q, struct request *rq)
{
	struct adios_data *ad = q->elevator->elevator_data;

	list_del_init(&rq->queuelist);

	/* 可能不在 rbtree 上(插入合并的情况) */
	if (!RB_EMPTY_NODE(&rq->rb_node))
		adios_del_rq_rb(ad, rq);

	elv_rqhash_del(q, rq);
	if (q->last_merge == rq)
		q->last_merge = NULL;
}

/* ---- 合并回调 ---- */

static void adios_request_merged(struct request_queue *q, struct request *req,
				 enum elv_merge type)
{
	struct adios_data *ad = q->elevator->elevator_data;

	/* 前端合并后需要重新定位请求在 rbtree 中的位置 */
	if (type == ELEVATOR_FRONT_MERGE) {
		elv_rb_del(adios_rb_root(ad, req), req);
		adios_add_rq_rb(ad, req);
	}
}

static void adios_merged_requests(struct request_queue *q, struct request *req,
				  struct request *next)
{
	/* 如果 next 比 req 先超时，将 next 的超时时间赋给 req，
	 * 并移动到 next 在 FIFO 中的位置 */
	if (!list_empty(&req->queuelist) && !list_empty(&next->queuelist)) {
		if (time_before((unsigned long)next->fifo_time,
				(unsigned long)req->fifo_time)) {
			list_move(&req->queuelist, &next->queuelist);
			req->fifo_time = next->fifo_time;
		}
	}

	adios_remove_request(q, next);
}

/* ---- FIFO 与排序查询 ---- */

/*
 * 检查 FIFO 中是否有请求已超时。
 * 返回 1 表示已超时(需要优先处理)，0 表示未超时。
 * 前提: fifo_list[ddir] 非空。
 */
static inline int adios_check_fifo(struct adios_data *ad, int ddir)
{
	struct request *rq = rq_entry_fifo(ad->fifo_list[ddir].next);

	if (time_after_eq(jiffies, (unsigned long)rq->fifo_time))
		return 1;
	return 0;
}

/* 获取指定方向的 FIFO 首个请求(最早到达的) */
static struct request *adios_fifo_request(struct adios_data *ad, int data_dir)
{
	if (list_empty(&ad->fifo_list[data_dir]))
		return NULL;

	return rq_entry_fifo(ad->fifo_list[data_dir].next);
}

/* 获取指定方向的 sort_list 下一个请求(按扇区序) */
static struct request *adios_next_request(struct adios_data *ad, int data_dir)
{
	return ad->next_rq[data_dir];
}

/* ---- 自适应延迟模型 ---- */

/*
 * 根据观测延迟动态调整 fifo_expire。
 * 当观测延迟持续高于 expire * adios_latency_factor 时，缩短 expire 以更积极地
 * 处理即将超时的请求; 反之则适度放宽 expire 以提高吞吐。
 */
static void adios_adjust_expire(struct adios_data *ad)
{
	int ddir;

	/* 限速: 每 fifo_batch*4 次完成才调整一次 */
	if (++ad->adjust_count < (unsigned int)(ad->fifo_batch * 4))
		return;
	ad->adjust_count = 0;

	for (ddir = READ; ddir <= WRITE; ddir++) {
		unsigned int latency_avg = (ddir == READ) ?
			ad->latency_avg_read : ad->latency_avg_write;
		unsigned int base = ad->base_expire[ddir];
		int new_expire;

		if (latency_avg == 0 || base == 0)
			continue;

		if (latency_avg > (unsigned int)base * adios_latency_factor) {
			/* 延迟过高: 缩短 expire 到基准的 3/4 */
			new_expire = (base * 3) / 4;
		} else if (latency_avg < (unsigned int)base / 2) {
			/* 延迟很低: 放宽 expire 到基准的 5/4(提高吞吐) */
			new_expire = (base * 5) / 4;
		} else {
			/* 延迟在合理范围: 恢复到基准 */
			new_expire = base;
		}

		/* 确保 expire 有合理下限 */
		if (new_expire < HZ / 10)
			new_expire = HZ / 10;

		ad->fifo_expire[ddir] = new_expire;
	}
}

/*
 * 更新延迟 EWMA。在请求完成时调用。
 */
static void adios_update_latency(struct adios_data *ad, int data_dir,
				 unsigned long latency)
{
	unsigned int *avg;

	if (latency == 0)
		return;

	avg = (data_dir == READ) ? &ad->latency_avg_read : &ad->latency_avg_write;

	if (*avg == 0)
		*avg = (unsigned int)latency;
	else
		/* EWMA: avg = (avg*(w-1) + latency) / w */
		*avg = (*avg * (adios_latency_ewma_weight - 1) +
			(unsigned int)latency) / adios_latency_ewma_weight;
}

/* ---- 派发逻辑 ---- */

/*
 * 将请求从 sort_list / fifo_list 移除，准备派发。
 */
static void adios_move_request(struct adios_data *ad, struct request *rq)
{
	const int data_dir = rq_data_dir(rq);

	ad->next_rq[READ] = NULL;
	ad->next_rq[WRITE] = NULL;
	ad->next_rq[data_dir] = adios_latter_request(rq);

	adios_remove_request(rq->q, rq);
}

/*
 * 核心派发函数: 选择最佳请求进行派发。
 *
 * 策略(自适应 deadline + 优先级):
 *   1. dispatch 队列非空时直接取(at_head / passthrough 请求)
 *   2. 批次未满时继续同方向派发(批量处理，减少开销)
 *   3. 选择方向:
 *      - 读优先(但受 writes_starved 限制)
 *      - 检查是否有超时请求(优先级提升)
 *   4. 在选定方向内:
 *      - 有超时请求 -> 从 FIFO 取(最早超时的)
 *      - 无超时请求 -> 从 sort_list 取(按扇区序，利于合并)
 */
static struct request *adios_dispatch_request(struct adios_data *ad)
{
	struct request *rq, *next_rq;
	bool reads, writes;
	int data_dir;

	/* 1. dispatch 队列优先(at_head / passthrough) */
	if (!list_empty(&ad->dispatch)) {
		rq = list_first_entry(&ad->dispatch, struct request, queuelist);
		list_del_init(&rq->queuelist);
		goto done;
	}

	reads = !list_empty(&ad->fifo_list[READ]);
	writes = !list_empty(&ad->fifo_list[WRITE]);

	/* 2. 批次未满: 继续同方向派发 */
	rq = adios_next_request(ad, WRITE);
	if (!rq)
		rq = adios_next_request(ad, READ);

	if (rq && ad->batching < (unsigned int)ad->fifo_batch)
		goto dispatch_request;

	/* 3. 选择方向 */
	if (reads) {
		/* 有写请求超时且读已让写饥饿过多 -> 派发写 */
		if (adios_fifo_request(ad, WRITE) &&
		    (ad->starved++ >= (unsigned int)ad->writes_starved))
			goto dispatch_writes;

		data_dir = READ;
		goto dispatch_find_request;
	}

	/* 没有读或写被饥饿 */
	if (writes) {
dispatch_writes:
		ad->starved = 0;
		data_dir = WRITE;
		goto dispatch_find_request;
	}

	return NULL;

dispatch_find_request:
	/*
	 * 4. 在选定方向内选择请求:
	 *    - 有超时请求(优先级提升) -> FIFO 首个
	 *    - 否则 -> sort_list 下一个(扇区序)
	 */
	next_rq = adios_next_request(ad, data_dir);
	if (adios_check_fifo(ad, data_dir) || !next_rq) {
		/* 有超时或已到 sort_list 末尾: 从 FIFO 重新开始 */
		rq = adios_fifo_request(ad, data_dir);
	} else {
		/* 继续按扇区序派发 */
		rq = next_rq;
	}

	if (!rq)
		return NULL;

	ad->batching = 0;

dispatch_request:
	/* 选定请求，移出队列并计数 */
	ad->batching++;
	adios_move_request(ad, rq);
done:
	rq->rq_flags |= RQF_STARTED;
	return rq;
}

/*
 * blk_mq_hw_ctx 级别的派发入口。
 * ADIOS 共享所有硬件队列的状态(与 mq-deadline 一致)。
 */
static struct request *adios_do_dispatch(struct blk_mq_hw_ctx *hctx)
{
	struct adios_data *ad = hctx->queue->elevator->elevator_data;
	struct request *rq;

	spin_lock(&ad->lock);
	rq = adios_dispatch_request(ad);
	spin_unlock(&ad->lock);

	return rq;
}

/* ---- 初始化与清理 ---- */

static void adios_exit_queue(struct elevator_queue *e)
{
	struct adios_data *ad = e->elevator_data;

	BUG_ON(!list_empty(&ad->fifo_list[READ]));
	BUG_ON(!list_empty(&ad->fifo_list[WRITE]));

	kfree(ad);
}

static int adios_init_queue(struct request_queue *q, struct elevator_type *e)
{
	struct adios_data *ad;
	struct elevator_queue *eq;

	eq = elevator_alloc(q, e);
	if (!eq)
		return -ENOMEM;

	ad = kzalloc_node(sizeof(*ad), GFP_KERNEL, q->node);
	if (!ad) {
		kobject_put(&eq->kobj);
		return -ENOMEM;
	}
	eq->elevator_data = ad;

	INIT_LIST_HEAD(&ad->fifo_list[READ]);
	INIT_LIST_HEAD(&ad->fifo_list[WRITE]);
	ad->sort_list[READ] = RB_ROOT;
	ad->sort_list[WRITE] = RB_ROOT;

	/* 初始化 expire 参数 */
	ad->fifo_expire[READ] = read_expire;
	ad->fifo_expire[WRITE] = write_expire;
	ad->base_expire[READ] = read_expire;
	ad->base_expire[WRITE] = write_expire;
	ad->writes_starved = writes_starved;
	ad->front_merges = 1;
	ad->fifo_batch = fifo_batch;

	/* 自适应延迟模型初始化 */
	ad->latency_avg_read = 0;
	ad->latency_avg_write = 0;
	ad->last_complete_time = jiffies;
	ad->adjust_count = 0;

	spin_lock_init(&ad->lock);
	INIT_LIST_HEAD(&ad->dispatch);

	q->elevator = eq;
	return 0;
}

/* ---- 合并与插入 ---- */

static int adios_request_merge(struct request_queue *q, struct request **rq,
			       struct bio *bio)
{
	struct adios_data *ad = q->elevator->elevator_data;
	sector_t sector = bio_end_sector(bio);
	struct request *__rq;

	if (!ad->front_merges)
		return ELEVATOR_NO_MERGE;

	__rq = elv_rb_find(&ad->sort_list[bio_data_dir(bio)], sector);
	if (__rq) {
		BUG_ON(sector != blk_rq_pos(__rq));

		if (elv_bio_merge_ok(__rq, bio)) {
			*rq = __rq;
			return ELEVATOR_FRONT_MERGE;
		}
	}

	return ELEVATOR_NO_MERGE;
}

static bool adios_bio_merge(struct blk_mq_hw_ctx *hctx, struct bio *bio)
{
	struct request_queue *q = hctx->queue;
	struct adios_data *ad = q->elevator->elevator_data;
	struct request *free = NULL;
	bool ret;

	spin_lock(&ad->lock);
	ret = blk_mq_sched_try_merge(q, bio, &free);
	spin_unlock(&ad->lock);

	if (free)
		blk_mq_free_request(free);

	return ret;
}

/*
 * 将单个请求插入到 rbtree + FIFO。
 */
static void adios_insert_request(struct blk_mq_hw_ctx *hctx, struct request *rq,
				 bool at_head)
{
	struct request_queue *q = hctx->queue;
	struct adios_data *ad = q->elevator->elevator_data;
	const int data_dir = rq_data_dir(rq);

	if (blk_mq_sched_try_insert_merge(q, rq))
		return;

	blk_mq_sched_request_inserted(rq);

	if (at_head || blk_rq_is_passthrough(rq)) {
		/* passthrough 或 at_head: 直接进入 dispatch 队列(最高优先级) */
		if (at_head)
			list_add(&rq->queuelist, &ad->dispatch);
		else
			list_add_tail(&rq->queuelist, &ad->dispatch);
	} else {
		/* 正常请求: 插入 rbtree(扇区序) 和 FIFO(到达序) */
		adios_add_rq_rb(ad, rq);

		if (rq_mergeable(rq)) {
			elv_rqhash_add(q, rq);
			if (!q->last_merge)
				q->last_merge = rq;
		}

		/*
		 * 设置超时时间并加入 FIFO。
		 * 使用当前自适应的 fifo_expire(可能已根据延迟调整)。
		 */
		rq->fifo_time = jiffies + ad->fifo_expire[data_dir];
		list_add_tail(&rq->queuelist, &ad->fifo_list[data_dir]);
	}
}

static void adios_insert_requests(struct blk_mq_hw_ctx *hctx,
				  struct list_head *list, bool at_head)
{
	struct adios_data *ad = hctx->queue->elevator->elevator_data;

	spin_lock(&ad->lock);
	while (!list_empty(list)) {
		struct request *rq;

		rq = list_first_entry(list, struct request, queuelist);
		list_del_init(&rq->queuelist);
		adios_insert_request(hctx, rq, at_head);
	}
	spin_unlock(&ad->lock);
}

/*
 * prepare_request: 仅占位，确保 finish_request 在完成时被调用。
 */
static void adios_prepare_request(struct request *rq, struct bio *bio)
{
}

/*
 * finish_request: 请求完成时更新自适应延迟模型。
 * 这是 ADIOS 的核心自适应入口: 记录请求从 STARTED 到完成的延迟，
 * 用于动态调整 fifo_expire。
 */
static void adios_finish_request(struct request *rq)
{
	struct request_queue *q = rq->q;
	struct adios_data *ad;
	unsigned long now, latency;
	int data_dir;

	if (!q->elevator)
		return;

	ad = q->elevator->elevator_data;
	if (!ad)
		return;

	/* 计算请求延迟: 从上次完成时间到现在的间隔(粗粒度近似) */
	now = jiffies;
	latency = now - ad->last_complete_time;
	ad->last_complete_time = now;

	data_dir = rq_data_dir(rq);

	/* 更新延迟 EWMA */
	adios_update_latency(ad, data_dir, latency);

	/* 自适应调整 expire */
	adios_adjust_expire(ad);
}

static bool adios_has_work(struct blk_mq_hw_ctx *hctx)
{
	struct adios_data *ad = hctx->queue->elevator->elevator_data;

	return !list_empty_careful(&ad->dispatch) ||
		!list_empty_careful(&ad->fifo_list[0]) ||
		!list_empty_careful(&ad->fifo_list[1]);
}

/*
 * completed_request 回调: 在 4.19 中签名为 void (*)(struct request *, u64)。
 * start_time_ns 为请求派发时的纳秒时间戳，可用于更精确的延迟统计。
 * 在 4.19 中该回调在请求完成后被调用，与 finish_request 互补:
 *   - finish_request 用于资源清理前置(每个请求都会调用)
 *   - completed_request 用于完成时的延迟统计(有 start_time_ns)
 * 此处使用 start_time_ns 计算请求的实际派发->完成延迟。
 */
static void adios_completed_request(struct request *rq, u64 start_time_ns)
{
	struct request_queue *q = rq->q;
	struct adios_data *ad;
	unsigned long now, latency;
	int data_dir;

	if (!q->elevator)
		return;

	ad = q->elevator->elevator_data;
	if (!ad)
		return;

	now = jiffies;

	/* 使用 start_time_ns 计算请求的实际延迟(纳秒 -> jiffies)。
	 * 若 start_time_ns 为 0(异常情况)，则回退到基于 last_complete_time 的估算。 */
	if (start_time_ns) {
		u64 elapsed_ns = sched_clock() - start_time_ns;
		latency = nsecs_to_jiffies(elapsed_ns);
	} else {
		latency = now - ad->last_complete_time;
	}
	ad->last_complete_time = now;

	data_dir = rq_data_dir(rq);
	adios_update_latency(ad, data_dir, latency);
	adios_adjust_expire(ad);
}

/* ---- sysfs 属性 ---- */

static ssize_t
adios_var_show(int var, char *page)
{
	return sprintf(page, "%d\n", var);
}

static void
adios_var_store(int *var, const char *page)
{
	char *p = (char *)page;

	*var = simple_strtol(p, &p, 10);
}

#define SHOW_FUNCTION(__FUNC, __VAR, __CONV)				\
static ssize_t __FUNC(struct elevator_queue *e, char *page)		\
{									\
	struct adios_data *ad = e->elevator_data;			\
	int __data = __VAR;						\
	if (__CONV)							\
		__data = jiffies_to_msecs(__data);			\
	return adios_var_show(__data, (page));				\
}
SHOW_FUNCTION(adios_read_expire_show, ad->fifo_expire[READ], 1);
SHOW_FUNCTION(adios_write_expire_show, ad->fifo_expire[WRITE], 1);
SHOW_FUNCTION(adios_writes_starved_show, ad->writes_starved, 0);
SHOW_FUNCTION(adios_front_merges_show, ad->front_merges, 0);
SHOW_FUNCTION(adios_fifo_batch_show, ad->fifo_batch, 0);
#undef SHOW_FUNCTION

#define STORE_FUNCTION(__FUNC, __PTR, MIN, MAX, __CONV)			\
static ssize_t __FUNC(struct elevator_queue *e, const char *page, size_t count) \
{									\
	struct adios_data *ad = e->elevator_data;			\
	int __data;							\
	adios_var_store(&__data, (page));				\
	if (__data < (MIN))						\
		__data = (MIN);						\
	else if (__data > (MAX))					\
		__data = (MAX);						\
	if (__CONV)							\
		*(__PTR) = msecs_to_jiffies(__data);			\
	else								\
		*(__PTR) = __data;					\
	return count;							\
}
STORE_FUNCTION(adios_read_expire_store, &ad->fifo_expire[READ], 0, INT_MAX, 1);
STORE_FUNCTION(adios_write_expire_store, &ad->fifo_expire[WRITE], 0, INT_MAX, 1);
STORE_FUNCTION(adios_writes_starved_store, &ad->writes_starved, INT_MIN, INT_MAX, 0);
STORE_FUNCTION(adios_front_merges_store, &ad->front_merges, 0, 1, 0);
STORE_FUNCTION(adios_fifo_batch_store, &ad->fifo_batch, 0, INT_MAX, 0);
#undef STORE_FUNCTION

#define ADIOS_ATTR(name) \
	__ATTR(name, 0644, adios_##name##_show, adios_##name##_store)

static struct elv_fs_entry adios_attrs[] = {
	ADIOS_ATTR(read_expire),
	ADIOS_ATTR(write_expire),
	ADIOS_ATTR(writes_starved),
	ADIOS_ATTR(front_merges),
	ADIOS_ATTR(fifo_batch),
	__ATTR_NULL
};

/* ---- 调度器注册 ---- */

static struct elevator_type adios_sched = {
	.ops.mq = {
		.insert_requests	= adios_insert_requests,
		.dispatch_request	= adios_do_dispatch,
		.prepare_request	= adios_prepare_request,
		.finish_request		= adios_finish_request,
		.next_request		= elv_rb_latter_request,
		.former_request		= elv_rb_former_request,
		.bio_merge		= adios_bio_merge,
		.request_merge		= adios_request_merge,
		.requests_merged	= adios_merged_requests,
		.request_merged		= adios_request_merged,
		.has_work		= adios_has_work,
		.init_sched		= adios_init_queue,
		.exit_sched		= adios_exit_queue,
		.completed_request	= adios_completed_request,
	},

	.uses_mq		= true,
	.elevator_attrs		= adios_attrs,
	.elevator_name		= "adios",
	.elevator_owner		= THIS_MODULE,
};

MODULE_ALIAS("adios-iosched");

static int __init adios_init(void)
{
	pr_info("ADIOS 3.2.0: 自适应截止时间 I/O 调度器已加载(4.19 兼容)\n");
	return elv_register(&adios_sched);
}

static void __exit adios_exit(void)
{
	elv_unregister(&adios_sched);
	pr_info("ADIOS 3.2.0: 已卸载\n");
}

module_init(adios_init);
module_exit(adios_exit);

MODULE_AUTHOR("Oblivionis-kernel project");
MODULE_DESCRIPTION("ADIOS 3.2.0: Adaptive Deadline I/O Scheduler (4.19 compat)");
MODULE_LICENSE("GPL");
MODULE_VERSION("3.2.0-4.19");
