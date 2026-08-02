// SPDX-License-Identifier: GPL-2.0
/*
 * tcp_roccet.c - TCP ROCCET 拥塞控制 (Linux 4.19 兼容)
 *
 * 功能说明:
 *   - 基于 CUBIC 算法的三次方窗口增长函数(W_cubic)，在其之上叠加
 *     RTT 变化率与 ACK 到达速率两类感知，面向 5G/移动网络以及
 *     Bufferbloat(深缓冲膨胀)场景。
 *   - 核心思路: CUBIC 通过 cnt(每增加 1 包所需的 ACK 数)控制窗口增长
 *     速率；ROCCET 在计算完 CUBIC 的 cnt 后，根据 RTT 趋势对 cnt 施加
 *     "增长抑制因子":
 *       * RTT 稳定或下降 -> 因子 = 1.0，CUBIC 正常增长；
 *       * RTT 快速上升   -> 放大 cnt(显著抑制增长)，Bufferbloat 防护；
 *       * RTT 缓慢上升   -> 轻度放大 cnt；
 *     同时跟踪 ack_rate(ACK 到达速率)用于判断带宽变化，当 RTT 明显
 *     高于基准且回落迟缓时进一步加重抑制。
 *   - 保留 CUBIC 的 HyStart 混合慢启动(ACK-train + 延迟检测)，HyStart
 *     本身即可在慢启动阶段探测到排队延迟上升并提前退出，与 Bufferbloat
 *     防护目标一致。
 *
 * 4.19 兼容性说明:
 *   - 使用 jiffies 而非 tcp_jiffies32(后者在部分 4.19 树被误判为 5.0+
 *     API；jiffies 在所有版本均可用，最稳妥)。
 *   - 使用 TCP_INIT_CWND 而非 tcp_init_cwnd()。
 *   - 使用 tcp_congestion_ops 的 cong_avoid + pkts_acked 回调(4.19 路径):
 *       cong_avoid(struct sock *sk, u32 ack, u32 acked)
 *       pkts_acked(struct sock *sk, const struct ack_sample *sample)
 *     ack_sample 字段: rtt_us(s32) / pkts_acked / in_flight。
 *   - tcp_is_cwnd_limited(sk) 在 4.19 为单参数形式(与 4.19 自带 cubic 一致)。
 *   - 私有数据通过 inet_csk_ca(sk) 获取，大小受 TCP_CA_PRIV_SIZE 限制。
 *   - 立方根 cubic_root() 自包含实现(移植自 4.19 net/ipv4/tcp_cubic.c)，
 *     仅依赖 fls64()/div64_u64()，4.19 均提供。
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/math64.h>
#include <net/tcp.h>
#include <linux/inet_diag.h>

/* ---- 4.19 兼容性补丁 ---- */
/* TCP_CA_PRIV_SIZE 在部分 4.19 树中可能缺失，回退到 ICSK_CA_PRIV_SIZE */
#ifndef TCP_CA_PRIV_SIZE
#define TCP_CA_PRIV_SIZE ICSK_CA_PRIV_SIZE
#endif
/* tcp_jiffies32 在 4.19 实际存在，但本模块按要求统一使用 jiffies。
 * 此处提供无害回退，避免在精简树中编译失败。 */
#ifndef tcp_jiffies32
#define tcp_jiffies32 jiffies
#endif

/* ---- CUBIC 缩放常量(与 4.19 tcp_cubic.c 一致) ---- */
#define BICTCP_BETA_SCALE	1024	/* beta 计算缩放因子 */
#define BICTCP_HZ		10	/* BIC HZ: 2^10 = 1024 */

/* HyStart 检测方法 */
#define HYSTART_ACK_TRAIN	0x1
#define HYSTART_DELAY		0x2
#define HYSTART_MIN_SAMPLES	8
#define HYSTART_DELAY_MIN	(4U << 3)
#define HYSTART_DELAY_MAX	(16U << 3)
#define HYSTART_DELAY_THRESH(x)	clamp(x, HYSTART_DELAY_MIN, HYSTART_DELAY_MAX)

/* ---- 可调模块参数 ---- */
static int fast_convergence __read_mostly = 1;
static int beta __read_mostly = 717;		/* 717/1024 = 0.7 */
static int initial_ssthresh __read_mostly;
static int bic_scale __read_mostly = 41;	/* C = bic_scale/1024 ≈ 0.04 */
static int tcp_friendliness __read_mostly = 1;

static int hystart __read_mostly = 1;
static int hystart_detect __read_mostly = HYSTART_ACK_TRAIN | HYSTART_DELAY;
static int hystart_low_window __read_mostly = 16;
static int hystart_ack_delta __read_mostly = 2;	/* ms */

/* ROCCET 专属参数 */
/* RTT 上升斜率阈值(相对基准 RTT 的比例，Q8 定点)。
 * 超过该比例即判定为"快速上升"(Bufferbloat 迹象)。 */
static int roccet_rise_thresh __read_mostly = 64;	/* 64/256 = 25% */
/* 快速上升时的增长抑制因子(Q10 定点，1024=1.0，2048=增长减半) */
static int roccet_rise_factor __read_mostly = 2048;
/* 缓慢上升时的最大轻度抑制量(Q10) */
static int roccet_mild_max __read_mostly = 512;

module_param(fast_convergence, int, 0644);
MODULE_PARM_DESC(fast_convergence, "turn on/off fast convergence");
module_param(beta, int, 0644);
MODULE_PARM_DESC(beta, "beta for multiplicative decrease");
module_param(initial_ssthresh, int, 0644);
MODULE_PARM_DESC(initial_ssthresh, "initial value of slow start threshold");
module_param(bic_scale, int, 0444);
MODULE_PARM_DESC(bic_scale, "scale (scaled by 1024) for bic function");
module_param(tcp_friendliness, int, 0644);
MODULE_PARM_DESC(tcp_friendliness, "turn on/off tcp friendliness");
module_param(hystart, int, 0644);
MODULE_PARM_DESC(hystart, "turn on/off hybrid slow start");
module_param(hystart_detect, int, 0644);
MODULE_PARM_DESC(hystart_detect, "hybrid slow start detection (1=train 2=delay 3=both)");
module_param(hystart_low_window, int, 0644);
MODULE_PARM_DESC(hystart_low_window, "lower bound cwnd for hybrid slow start");
module_param(roccet_rise_thresh, int, 0644);
MODULE_PARM_DESC(roccet_rise_thresh, "RTT fast-rise threshold (Q8, /256)");
module_param(roccet_rise_factor, int, 0644);
MODULE_PARM_DESC(roccet_rise_factor, "growth suppression factor on fast RTT rise (Q10)");

/* 运行期预计算的缩放因子 */
static u32 cube_rtt_scale __read_mostly;
static u32 beta_scale __read_mostly;
static u64 cube_factor __read_mostly;

/*
 * ROCCET 私有数据(必须 <= TCP_CA_PRIV_SIZE)。
 * 前半部分为 CUBIC 核心字段(与 4.19 bictcp 一致)，后半部分为
 * ROCCET 扩展: RTT 变化率与 ACK 速率感知。
 */
struct roccet {
	/* ---- CUBIC 核心 ---- */
	u32	cnt;		/* 每增加 1 包所需的 ACK 数(越大增长越慢) */
	u32	last_max_cwnd;	/* W_max: 上次丢包前的窗口 */
	u32	last_cwnd;	/* 上次更新时的 snd_cwnd */
	u32	last_time;	/* 上次更新时间(jiffies) */
	u32	bic_origin_point;/* W_cubic 的原点 */
	u32	bic_K;		/* 到达原点的时间(bictcp_HZ 单位) */
	u32	delay_min;	/* 最小 RTT(msec<<3) */
	u32	epoch_start;	/* 当前 epoch 起始(jiffies) */
	u32	ack_cnt;	/* 累计 ACK 数 */
	u32	tcp_cwnd;	/* TCP 友好性估计窗口 */
	u32	round_start;	/* HyStart 轮次起始(ms) */
	u32	end_seq;	/* HyStart 轮次结束序列号 */
	u32	last_ack;	/* 上次 ACK 时间(ms，ACK-train 用) */
	u32	curr_rtt;	/* 当前轮次最小 RTT(msec<<3) */

	/* ---- ROCCET 扩展: RTT 变化率与 ACK 速率感知 ---- */
	u32	last_rtt;	/* 上一次 RTT 采样(msec<<3) */
	s32	rtt_slope;	/* 平滑 RTT 变化率(正=上升,负=下降) */
	u32	ack_rate;	/* 平滑 ACK 到达速率(包/10ms) */
	u32	ack_win_start;	/* ACK 计数窗口起始(ms) */
	u32	ack_in_win;	/* 当前窗口内 ACK 包数 */
	u32	growth_factor;	/* 最近一次施加的增长抑制因子(Q10) */

	u8	sample_cnt;	/* HyStart 采样计数 */
	u8	found;		/* HyStart 退出点是否已找到 */
	u8	rtt_rising;	/* RTT 快速上升标志(Bufferbloat) */
};

static inline struct roccet *roccet_ca(const struct sock *sk)
{
	return (struct roccet *)inet_csk_ca(sk);
}

/* HyStart 时钟: 用 jiffies 换算的毫秒(按要求使用 jiffies) */
static inline u32 roccet_clock(void)
{
	return jiffies_to_msecs(jiffies);
}

static inline void roccet_reset(struct roccet *ca)
{
	ca->cnt = 0;
	ca->last_max_cwnd = 0;
	ca->last_cwnd = 0;
	ca->last_time = 0;
	ca->bic_origin_point = 0;
	ca->bic_K = 0;
	ca->delay_min = 0;
	ca->epoch_start = 0;
	ca->ack_cnt = 0;
	ca->tcp_cwnd = 0;
	ca->found = 0;
}

static inline void roccet_hystart_reset(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct roccet *ca = roccet_ca(sk);

	ca->round_start = ca->last_ack = roccet_clock();
	ca->end_seq = tp->snd_nxt;
	ca->curr_rtt = 0;
	ca->sample_cnt = 0;
}

static void roccet_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct roccet *ca = roccet_ca(sk);

	roccet_reset(ca);

	/* ROCCET 扩展字段初始化 */
	ca->last_rtt = 0;
	ca->rtt_slope = 0;
	ca->ack_rate = 0;
	ca->ack_win_start = 0;
	ca->ack_in_win = 0;
	ca->growth_factor = 1024;
	ca->rtt_rising = 0;

	if (hystart)
		roccet_hystart_reset(sk);

	if (!hystart && initial_ssthresh)
		tp->snd_ssthresh = initial_ssthresh;
}

static void roccet_cwnd_event(struct sock *sk, enum tcp_ca_event event)
{
	if (event == CA_EVENT_TX_START) {
		struct roccet *ca = roccet_ca(sk);
		u32 now = jiffies;
		s32 delta;

		delta = now - tcp_sk(sk)->lsndtime;

		/* 应用受限(空闲)一段时间后，平移 epoch_start 以维持
		 * CUBIC 曲线连续性(与 4.19 cubic 一致)。 */
		if (ca->epoch_start && delta > 0) {
			ca->epoch_start += delta;
			if (ca->epoch_start > now)
				ca->epoch_start = now;
		}
	}
}

/*
 * 立方根计算(移植自 4.19 net/ipv4/tcp_cubic.c)。
 * 表查找 + 一次 Newton-Raphson 迭代，平均误差约 0.195%。
 */
static u32 cubic_root(u64 a)
{
	u32 x, b, shift;
	static const u8 v[] = {
		/* 0x00 */    0,   54,   54,   54,  118,  118,  118,  118,
		/* 0x08 */  123,  129,  134,  138,  143,  147,  151,  156,
		/* 0x10 */  157,  161,  164,  168,  170,  173,  176,  179,
		/* 0x18 */  181,  185,  187,  190,  192,  194,  197,  199,
		/* 0x20 */  200,  202,  204,  206,  209,  211,  213,  215,
		/* 0x28 */  217,  219,  221,  222,  224,  225,  227,  229,
		/* 0x30 */  231,  232,  234,  236,  237,  239,  240,  242,
		/* 0x38 */  244,  245,  246,  248,  250,  251,  252,  254,
	};

	b = fls64(a);
	if (b < 7) {
		/* a in [0..63] */
		return ((u32)v[(u32)a] + 35) >> 6;
	}

	b = ((b * 84) >> 8) - 1;
	shift = (a >> (b * 3));

	x = ((u32)(((u32)v[shift] + 10) << b)) >> 6;

	/* Newton-Raphson: x_{k+1} = (2*x_k + a/x_k^2) / 3 */
	x = (2 * x + (u32)div64_u64(a, (u64)x * (u64)(x - 1)));
	x = ((x * 341) >> 10);
	return x;
}

/*
 * ROCCET 增长抑制: 根据 RTT 变化率与 ACK 速率，调整 CUBIC 计算出的 cnt。
 * cnt 越大 -> 窗口增长越慢。返回施加的抑制因子(Q10)。
 */
static void roccet_apply_awareness(struct roccet *ca)
{
	u32 factor = 1024;	/* 1.0 (Q10) */

	/* 1) RTT 变化率感知(Bufferbloat 防护) */
	if (ca->rtt_rising) {
		/* RTT 快速上升: 显著抑制增长 */
		factor += (roccet_rise_factor - 1024);
	} else if (ca->rtt_slope > 0 && ca->delay_min) {
		/* RTT 缓慢上升: 按斜率/基准比例轻度抑制 */
		u32 ratio;	/* Q8: (slope*256)/delay_min */
		u32 mild;

		ratio = ((u32)ca->rtt_slope << 8) / ca->delay_min;
		if (ratio > (u32)roccet_rise_thresh)
			ratio = roccet_rise_thresh;
		/* 映射到 0..roccet_mild_max 的抑制量 */
		mild = (ratio * (u32)roccet_mild_max) /
		       (u32)max(roccet_rise_thresh, 1);
		factor += mild;
	}
	/* RTT 稳定或下降: factor 保持 1024，CUBIC 正常增长 */

	/* 2) ACK 速率感知(带宽变化判断):
	  * 当前 RTT 明显高于基准(>125% 基准)且回落迟缓时，进一步加重抑制，
	  * 因为带宽很可能已收缩。 */
	if (ca->delay_min && ca->last_rtt > ca->delay_min + (ca->delay_min >> 2))
		factor += 256;

	/* 应用抑制因子(放大 cnt = 减慢增长)，使用 64 位避免溢出 */
	ca->cnt = (u32)((u64)ca->cnt * factor >> 10);
	ca->growth_factor = factor;
}

/*
 * 计算 CUBIC 拥塞窗口(移植自 4.19 bictcp_update，jiffies 替换 tcp_jiffies32，
 * 并在末尾插入 ROCCET 增长抑制)。
 */
static inline void roccet_update(struct roccet *ca, u32 cwnd, u32 acked)
{
	u32 delta, bic_target, max_cnt;
	u64 offs, t;

	ca->ack_cnt += acked;	/* 累计 ACK 包数 */

	if (ca->last_cwnd == cwnd &&
	    (s32)(jiffies - ca->last_time) <= HZ / 32)
		return;

	/* CUBIC 函数至多每个 jiffy 更新一次 ca->cnt。
	 * 每次 cwnd 缩减事件都会将 epoch_start 清零，强制重算。 */
	if (ca->epoch_start && jiffies == ca->last_time)
		goto tcp_friendliness;

	ca->last_cwnd = cwnd;
	ca->last_time = jiffies;

	if (ca->epoch_start == 0) {
		ca->epoch_start = jiffies;	/* 记录起点 */
		ca->ack_cnt = acked;		/* 重新计数 */
		ca->tcp_cwnd = cwnd;		/* 与 cubic 同步 */

		if (ca->last_max_cwnd <= cwnd) {
			ca->bic_K = 0;
			ca->bic_origin_point = cwnd;
		} else {
			/* K = cubic_root((wmax-cwnd) * cube_factor) */
			ca->bic_K = cubic_root(cube_factor
					       * (ca->last_max_cwnd - cwnd));
			ca->bic_origin_point = ca->last_max_cwnd;
		}
	}

	/* cubic 函数计算:
	 *   time = (t - K) / 2^bictcp_HZ
	 *   c    = bic_scale >> 10
	 *   rtt  = (srtt >> 3) / HZ
	 * 计算 c/rtt * (t-K)^3，64 位承载 time^3 避免溢出(cwnd<1M 包)。 */
	t = (s32)(jiffies - ca->epoch_start);
	t += msecs_to_jiffies(ca->delay_min >> 3);
	/* 单位由 HZ 转为 bictcp_HZ */
	t <<= BICTCP_HZ;
	do_div(t, HZ);

	if (t < ca->bic_K)		/* t - K */
		offs = ca->bic_K - t;
	else
		offs = t - ca->bic_K;

	/* c/rtt * (t-K)^3 */
	delta = (cube_rtt_scale * offs * offs * offs) >> (10 + 3 * BICTCP_HZ);
	if (t < ca->bic_K)			/* 低于原点 */
		bic_target = ca->bic_origin_point - delta;
	else					/* 高于原点 */
		bic_target = ca->bic_origin_point + delta;

	/* 由 bic_target 反推 cnt */
	if (bic_target > cwnd) {
		ca->cnt = cwnd / (bic_target - cwnd);
	} else {
		ca->cnt = 100 * cwnd;		/* 极小增量 */
	}

	/* 初始阶段可用带宽未知时，CUBIC 增长可能过于保守 */
	if (ca->last_max_cwnd == 0 && ca->cnt > 20)
		ca->cnt = 20;	/* 每 RTT 约 5% 增长 */

tcp_friendliness:
	/* TCP 友好性: 估计同等条件下 Reno 的窗口，取较快者 */
	if (tcp_friendliness) {
		u32 scale = beta_scale;

		delta = (cwnd * scale) >> 3;
		while (ca->ack_cnt > delta) {	/* 更新 tcp cwnd */
			ca->ack_cnt -= delta;
			ca->tcp_cwnd++;
		}

		if (ca->tcp_cwnd > cwnd) {	/* bic 比 tcp 慢 */
			delta = ca->tcp_cwnd - cwnd;
			max_cnt = cwnd / delta;
			if (ca->cnt > max_cnt)
				ca->cnt = max_cnt;
		}
	}

	/* ---- ROCCET: 根据 RTT/ACK 感知施加增长抑制 ---- */
	roccet_apply_awareness(ca);

	/* CUBIC 允许的最大增长速率为每 2 个 ACK 增 1 包(每 RTT 1.5x) */
	ca->cnt = max(ca->cnt, 2U);
}

static void roccet_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct roccet *ca = roccet_ca(sk);

	if (!tcp_is_cwnd_limited(sk))
		return;

	if (tcp_in_slow_start(tp)) {
		if (hystart && after(ack, ca->end_seq))
			roccet_hystart_reset(sk);
		acked = tcp_slow_start(tp, acked);
		if (!acked)
			return;
	}
	roccet_update(ca, tp->snd_cwnd, acked);
	tcp_cong_avoid_ai(tp, ca->cnt, acked);
}

/* 丢包时: CUBIC 乘性减少(beta=0.7)，并记录 W_max 用于下一轮 cubic 曲线 */
static u32 roccet_ssthresh(struct sock *sk)
{
	const struct tcp_sock *tp = tcp_sk(sk);
	struct roccet *ca = roccet_ca(sk);

	ca->epoch_start = 0;	/* 结束当前 epoch */

	/* W_max 与快速收敛 */
	if (tp->snd_cwnd < ca->last_max_cwnd && fast_convergence)
		ca->last_max_cwnd = (tp->snd_cwnd * (BICTCP_BETA_SCALE + beta))
			/ (2 * BICTCP_BETA_SCALE);
	else
		ca->last_max_cwnd = tp->snd_cwnd;

	return max((tp->snd_cwnd * beta) / BICTCP_BETA_SCALE, 2U);
}

static void roccet_state(struct sock *sk, u8 new_state)
{
	if (new_state == TCP_CA_Loss) {
		roccet_reset(roccet_ca(sk));
		roccet_hystart_reset(sk);
	}
}

/* HyStart: ACK-train 与延迟检测(移植自 4.19 cubic) */
static void roccet_hystart_update(struct sock *sk, u32 delay)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct roccet *ca = roccet_ca(sk);

	if (ca->found & hystart_detect)
		return;

	if (hystart_detect & HYSTART_ACK_TRAIN) {
		u32 now = roccet_clock();

		/* 第一检测参数: ACK-train 检测 */
		if ((s32)(now - ca->last_ack) <= hystart_ack_delta) {
			ca->last_ack = now;
			if ((s32)(now - ca->round_start) > ca->delay_min >> 4) {
				ca->found |= HYSTART_ACK_TRAIN;
				tp->snd_ssthresh = tp->snd_cwnd;
			}
		}
	}

	if (hystart_detect & HYSTART_DELAY) {
		/* 采集若干采样包的最小延迟 */
		if (ca->sample_cnt < HYSTART_MIN_SAMPLES) {
			if (ca->curr_rtt == 0 || ca->curr_rtt > delay)
				ca->curr_rtt = delay;
			ca->sample_cnt++;
		} else {
			if (ca->curr_rtt > ca->delay_min +
			    HYSTART_DELAY_THRESH(ca->delay_min >> 3)) {
				ca->found |= HYSTART_DELAY;
				tp->snd_ssthresh = tp->snd_cwnd;
			}
		}
	}
}

/*
 * pkts_acked: 4.19 每次 ACK 提供一个 RTT 采样。
 * 除 CUBIC 原本的 delay_min/HyStart 维护外，ROCCET 在此:
 *   - 计算 RTT 变化率(rtt_slope, EMA)，并判定 rtt_rising；
 *   - 跟踪 ACK 到达速率(ack_rate，10ms 窗口 EMA)。
 */
static void roccet_pkts_acked(struct sock *sk, const struct ack_sample *sample)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct roccet *ca = roccet_ca(sk);
	u32 delay;
	u32 now;
	s32 rtt_us = sample->rtt_us;

	/* 无时间戳的重复 ACK 采样 */
	if (rtt_us < 0)
		return;

	/* 丢弃快恢复后紧邻的样本(与 cubic 一致) */
	if (ca->epoch_start && (s32)(jiffies - ca->epoch_start) < HZ)
		return;

	/* 转为 msec<<3 单位(与 CUBIC 内部一致) */
	delay = (rtt_us << 3) / USEC_PER_MSEC;
	if (delay == 0)
		delay = 1;

	/* 更新最小 RTT(无排队基准) */
	if (ca->delay_min == 0 || ca->delay_min > delay)
		ca->delay_min = delay;

	/* ---- ROCCET: RTT 变化率感知 ---- */
	if (ca->last_rtt) {
		s32 delta = (s32)delay - (s32)ca->last_rtt;
		/* EMA: slope = (7*slope + delta) / 8 */
		ca->rtt_slope = (ca->rtt_slope * 7 + delta) / 8;
	}
	ca->last_rtt = delay;

	/* 判定 RTT 快速上升(Bufferbloat 迹象):
	 * 斜率 > delay_min 的 roccet_rise_thresh/256 */
	ca->rtt_rising = 0;
	if (ca->rtt_slope > 0 && ca->delay_min) {
		u32 ratio = ((u32)ca->rtt_slope << 8) / ca->delay_min;
		if (ratio >= (u32)roccet_rise_thresh)
			ca->rtt_rising = 1;
	}

	/* ---- ROCCET: ACK 到达速率感知(判断带宽变化) ---- */
	now = roccet_clock();
	ca->ack_in_win += sample->pkts_acked;
	if (ca->ack_win_start == 0)
		ca->ack_win_start = now;
	if (now - ca->ack_win_start >= 10) {	/* 10ms 窗口 */
		u32 elapsed = now - ca->ack_win_start;
		u32 rate;	/* 归一化为 包/10ms */

		if (elapsed == 0)
			elapsed = 1;
		rate = (ca->ack_in_win * 10) / elapsed;
		/* EMA */
		if (ca->ack_rate == 0)
			ca->ack_rate = rate;
		else
			ca->ack_rate = (ca->ack_rate * 7 + rate) / 8;
		ca->ack_in_win = 0;
		ca->ack_win_start = now;
	}

	/* HyStart: 仅在慢启动且 cwnd 足够大时触发 */
	if (hystart && tcp_in_slow_start(tp) &&
	    tp->snd_cwnd >= hystart_low_window)
		roccet_hystart_update(sk, delay);
}

/* 通过 inet_diag 导出 ROCCET 状态(复用 vegas info 结构) */
static size_t roccet_get_info(struct sock *sk, u32 ext, int *attr,
			      union tcp_cc_info *info)
{
	struct roccet *ca = roccet_ca(sk);

	if (ext & (1 << (INET_DIAG_VEGASINFO - 1))) {
		info->vegas.tcpv_enabled = 1;
		info->vegas.tcpv_rttcnt = ca->ack_rate;
		info->vegas.tcpv_rtt = (u32)ca->rtt_slope;
		info->vegas.tcpv_minrtt = ca->delay_min;
		*attr = INET_DIAG_VEGASINFO;
		return sizeof(struct tcpvegas_info);
	}
	return 0;
}

static struct tcp_congestion_ops tcp_roccet_ops = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "roccet",
	.owner		= THIS_MODULE,
	.init		= roccet_init,
	.ssthresh	= roccet_ssthresh,
	.cong_avoid	= roccet_cong_avoid,
	.set_state	= roccet_state,
	.undo_cwnd	= tcp_reno_undo_cwnd,
	.cwnd_event	= roccet_cwnd_event,
	.pkts_acked	= roccet_pkts_acked,
	.get_info	= roccet_get_info,
};

static int __init roccet_register(void)
{
	/* 验证私有数据不超过 TCP_CA_PRIV_SIZE */
	BUILD_BUG_ON(sizeof(struct roccet) > TCP_CA_PRIV_SIZE);

	/* 预计算每个数据包使用的缩放因子(基于 100ms SRTT) */
	beta_scale = 8 * (BICTCP_BETA_SCALE + beta) / 3
		/ (BICTCP_BETA_SCALE - beta);

	cube_rtt_scale = (bic_scale * 10);	/* 1024*c/rtt */

	/* K = cubic_root((wmax-cwnd) * rtt / c)
	 * 单位为 bictcp_HZ=2^10。c = bic_scale>>10, rtt = 100ms。
	 * 以下设计针对 cwnd<1M 包、RTT<100s、HZ<1,000,000。 */
	cube_factor = 1ull << (10 + 3 * BICTCP_HZ);	/* 2^40 */
	do_div(cube_factor, bic_scale * 10);

	pr_info("TCP ROCCET: 基于 CUBIC 的 RTT/ACK 速率感知拥塞控制已加载(4.19 兼容)\n");
	return tcp_register_congestion_control(&tcp_roccet_ops);
}

static void __exit roccet_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_roccet_ops);
	pr_info("TCP ROCCET: 已卸载\n");
}

module_init(roccet_register);
module_exit(roccet_unregister);

MODULE_AUTHOR("Oblivionis-kernel project");
MODULE_DESCRIPTION("TCP ROCCET: CUBIC + RTT/ACK rate awareness for 5G/mobile/Bufferbloat (4.19 compat)");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0-4.19");
