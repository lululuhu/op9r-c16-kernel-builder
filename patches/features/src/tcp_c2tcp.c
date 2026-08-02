// SPDX-License-Identifier: GPL-2.0
/*
 * tcp_c2tcp.c - C2TCP 低延迟拥塞控制 (Linux 4.19 兼容)
 *
 * 功能说明:
 *   - 面向蜂窝网络与深缓冲(deep-buffer)网络的低延迟拥塞控制
 *   - 延迟感知: 当排队延迟上升时主动降低 cwnd，尽量维持吞吐的同时
 *     降低网络排队延迟
 *   - 以"最小 RTT(baseRTT)"作为无排队基准，用当前 RTT 与之差值
 *     估计排队延迟: queue_delay = avgRTT - baseRTT
 *   - 排队延迟超过阈值时，采用类 Vegas 的乘性减少(MD)降低 cwnd
 *   - 延迟恢复正常时，采用加性增长(AI)提升 cwnd
 *
 * 4.19 兼容性说明:
 *   - 使用 jiffies 而非 tcp_jiffies32(后者 5.0 引入，4.19 不存在)
 *   - 使用 TCP_INIT_CWND 而非 tcp_init_cwnd()
 *   - 使用 tcp_congestion_ops 的 cong_avoid + pkts_acked 回调
 *     (类 Vegas 路径；4.19 中 cong_avoid 形参为 ack/acked)
 *   - pkts_acked 使用 4.19 的 struct ack_sample(rtt_us/pkts_acked/in_flight)
 *   - 私有数据通过 inet_csk_ca(sk) 获取，大小受 TCP_CA_PRIV_SIZE 限制
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <net/tcp.h>
#include <linux/inet_diag.h>

/* ---- 4.19 兼容性补丁 ---- */
#ifndef TCP_CA_PRIV_SIZE
#define TCP_CA_PRIV_SIZE ICSK_CA_PRIV_SIZE
#endif

/* 排队延迟阈值(微秒)，可通过模块参数调节；默认 25ms */
static unsigned int c2tcp_threshold __read_mostly = 25000;
module_param(c2tcp_threshold, uint, 0644);
MODULE_PARM_DESC(c2tcp_threshold,
		 "排队延迟阈值(微秒)，超过该值则降低 cwnd(默认 25000)");

/* C2TCP 私有数据(必须 <= TCP_CA_PRIV_SIZE) */
struct c2tcp {
	u32	baseRTT;	/* 最小 RTT(微秒)，作为无排队基准 */
	u32	minRTT;		/* 当前测量周期内的最小 RTT */
	u32	cntRTT;		/* 当前周期采样数 */
	u32	sumRTT;		/* 当前周期 RTT 累加(微秒) */
	u32	beg_snd_nxt;	/* 当前周期起始的 snd_nxt */
	u8	doing_c2tcp;	/* 是否启用延迟感知 */
};

static inline struct c2tcp *c2tcp_ca(const struct sock *sk)
{
	return (struct c2tcp *)inet_csk_ca(sk);
}

/* 重置一个 RTT 测量周期 */
static void c2tcp_reset(struct sock *sk)
{
	struct c2tcp *ca = c2tcp_ca(sk);

	ca->minRTT = ~0U;
	ca->cntRTT = 0;
	ca->sumRTT = 0;
	ca->beg_snd_nxt = tcp_sk(sk)->snd_nxt;
}

static void c2tcp_init(struct sock *sk)
{
	struct c2tcp *ca = c2tcp_ca(sk);

	ca->baseRTT = 0;
	ca->doing_c2tcp = 1;
	c2tcp_reset(sk);
}

/* pkts_acked: 4.19 在每次 ACK 时提供 RTT 采样 */
static void c2tcp_pkts_acked(struct sock *sk, const struct ack_sample *sample)
{
	struct c2tcp *ca = c2tcp_ca(sk);
	s32 rtt = sample->rtt_us;	/* ack_sample.rtt_us 为 s32 */

	if (rtt <= 0)
		return;

	/* 更新基准 RTT(历史最小值) */
	if (ca->baseRTT == 0 || (u32)rtt < ca->baseRTT)
		ca->baseRTT = (u32)rtt;

	/* 当前周期采样累加 */
	if ((u32)rtt < ca->minRTT)
		ca->minRTT = (u32)rtt;
	ca->sumRTT += (u32)rtt;
	ca->cntRTT++;
}

/*
 * cong_avoid: 4.19 拥塞避免主入口。
 * 形参: ack = 当前 ACK 序列号, acked = 本轮新确认包数。
 * 采用 Vegas 风格的按 RTT 周期评估排队延迟。
 */
static void c2tcp_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct c2tcp *ca = c2tcp_ca(sk);

	/* 4.19: tcp_is_cwnd_limited 需要 in_flight 参数，
	 * cong_avoid 的第三个参数是 acked(新确认包数)而非 in_flight，
	 * 因此用 tcp_packets_in_flight() 获取真实在途包数。 */
	if (!tcp_is_cwnd_limited(sk, tcp_packets_in_flight(tp)))
		return;

	/*
	 * 新 RTT 周期检测: 当 snd_una 越过周期起始的 snd_nxt 时，
	 * 表示本周期发送的数据已被确认，可评估排队延迟。
	 */
	if (ca->doing_c2tcp && after(tp->snd_una, ca->beg_snd_nxt)) {
		if (ca->cntRTT > 0 && ca->baseRTT > 0) {
			u32 avgRTT = ca->sumRTT / ca->cntRTT;
			u32 queue_delay;

			queue_delay = (avgRTT > ca->baseRTT) ?
				      (avgRTT - ca->baseRTT) : 0;

			if (queue_delay > c2tcp_threshold) {
				/*
				 * 排队延迟过大: 乘性减少(类 Vegas/MD)，
				 * 主动排空队列以降低延迟。
				 */
				tp->snd_cwnd = max_t(u32, tp->snd_cwnd >> 1,
						     TCP_INIT_CWND);
				tp->snd_ssthresh = tp->snd_cwnd;
			}
			/* 延迟正常: 由下方 AI 加性增长 */
		}

		/* 进入下一个测量周期 */
		c2tcp_reset(sk);
	}

	if (tcp_in_slow_start(tp))
		tcp_slow_start(tp, acked);
	else
		/* 加性增长(AI): 每 RTT cwnd 约增加 1 */
		tcp_cong_avoid_ai(tp, tp->snd_cwnd, acked);
}

/* 丢包时: 标准减半(与延迟感知的 MD 互为补充) */
static u32 c2tcp_ssthresh(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);

	return max_t(u32, tp->snd_cwnd >> 1, TCP_INIT_CWND);
}

static u32 c2tcp_undo_cwnd(struct sock *sk)
{
	return tcp_sk(sk)->snd_cwnd;
}

static void c2tcp_state(struct sock *sk, u8 new_state)
{
	/* 进入 Loss 状态时重置测量周期 */
	if (new_state == TCP_CA_Loss)
		c2tcp_reset(sk);
}

static void c2tcp_cwnd_event(struct sock *sk, enum tcp_ca_event ev)
{
	/* 空闲重启后重新建立基准 RTT */
	if (ev == CA_EVENT_CWND_RESTART)
		c2tcp_reset(sk);
}

/* 通过 inet_diag 导出状态(复用 vegas info 结构) */
static size_t c2tcp_get_info(struct sock *sk, u32 ext, int *attr,
			     union tcp_cc_info *info)
{
	struct c2tcp *ca = c2tcp_ca(sk);

	if (ext & (1 << (INET_DIAG_VEGASINFO - 1))) {
		info->vegas.tcpv_enabled = ca->doing_c2tcp;
		info->vegas.tcpv_rttcnt = ca->cntRTT;
		info->vegas.tcpv_rtt = ca->minRTT;
		info->vegas.tcpv_minrtt = ca->baseRTT;
		*attr = INET_DIAG_VEGASINFO;
		return sizeof(struct tcpvegas_info);
	}
	return 0;
}

static struct tcp_congestion_ops tcp_c2tcp_ops = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "c2tcp",
	.owner		= THIS_MODULE,
	.init		= c2tcp_init,
	.pkts_acked	= c2tcp_pkts_acked,
	.cong_avoid	= c2tcp_cong_avoid,
	.set_state	= c2tcp_state,
	.cwnd_event	= c2tcp_cwnd_event,
	.ssthresh	= c2tcp_ssthresh,
	.undo_cwnd	= c2tcp_undo_cwnd,
	.get_info	= c2tcp_get_info,
};

static int __init c2tcp_register(void)
{
	/* 验证私有数据不超过 TCP_CA_PRIV_SIZE */
	BUILD_BUG_ON(sizeof(struct c2tcp) > TCP_CA_PRIV_SIZE);

	pr_info("C2TCP: 蜂窝/深缓冲低延迟拥塞控制已加载(4.19 兼容)\n");
	return tcp_register_congestion_control(&tcp_c2tcp_ops);
}

static void __exit c2tcp_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_c2tcp_ops);
	pr_info("C2TCP: 已卸载\n");
}

module_init(c2tcp_register);
module_exit(c2tcp_unregister);

MODULE_AUTHOR("Oblivionis-kernel project");
MODULE_DESCRIPTION("C2TCP cellular low-latency TCP congestion control (4.19 compat)");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0-4.19");
