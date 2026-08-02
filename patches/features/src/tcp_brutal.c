// SPDX-License-Identifier: GPL-2.0
/*
 * tcp_brutal.c - TCP Brutal 速率型拥塞控制 (Linux 4.19 兼容)
 *
 * 功能说明:
 *   - 基于速率(rate-based)的拥塞控制，不以 AIMD 窗口调整为核心
 *   - 应用通过 setsockopt(TCP_BRUTAL_RATE) 设置目标发送速率(字节/秒)
 *   - 维持拥塞窗口: cwnd = rate * rtt / mss
 *   - 丢包时不降低速率(每次 ACK 重新设为目标窗口)
 *   - 默认启用 ECN 协商
 *
 * 4.19 兼容性说明:
 *   - 使用 jiffies 而非 tcp_jiffies32(后者在 5.0 引入，4.19 不存在)
 *   - 使用 TCP_INIT_CWND 而非 tcp_init_cwnd()
 *   - 使用 tcp_congestion_ops.cong_control 回调(覆盖默认 cong_avoid)
 *   - 私有数据通过 inet_csk_ca(sk) 获取，大小受 TCP_CA_PRIV_SIZE 限制
 *   - 参考 4.19 rate_sample 结构体字段:
 *       delivered / interval_us / rtt_us / losses / is_app_limited
 *   - setsockopt 通过覆盖 struct proto(仅 IPv4)拦截，无需改动 tcp.c
 *     (与上游 apernet/tcp-brutal 思路一致；IPv6 拦截需 >=5.8 额外扩展)
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
/* sk_pacing_status / SK_PACING_* 自 4.13 起存在，此处防御性定义 */
#ifndef SK_PACING_NONE
#define SK_PACING_NONE 0
#endif
#ifndef SK_PACING_NEEDED
#define SK_PACING_NEEDED 1
#endif

/*
 * 自定义 socket 选项编号。
 * 与上游 apernet/tcp-brutal 取同一编号(23301)，便于工具识别。
 * 上游命名为 TCP_BRUTAL_PARAMS 并携带 {rate, cwnd_gain} 结构；
 * 本模块按需求仅接收一个 u32 目标速率。
 */
#define TCP_BRUTAL_RATE 23301

/* Brutal 私有数据(必须 <= TCP_CA_PRIV_SIZE) */
struct brutal {
	u32	rate;		/* 目标发送速率(字节/秒)；0 表示未设置 */
};

static inline struct brutal *brutal_ca(const struct sock *sk)
{
	return (struct brutal *)inet_csk_ca(sk);
}

/* ---- setsockopt 拦截: 覆盖 struct proto ----
 * 4.19 的 proto.setsockopt 使用 char __user *optval；
 * 5.9+ 改用 sockptr_t。用 _LINUX_SOCKPTR_H 宏同时兼容两者。
 */
static struct proto tcp_prot_override;

#ifdef _LINUX_SOCKPTR_H
static int brutal_set_rate(struct sock *sk, sockptr_t optval,
			   unsigned int optlen)
#else
static int brutal_set_rate(struct sock *sk, char __user *optval,
			   unsigned int optlen)
#endif
{
	struct brutal *ca = brutal_ca(sk);
	u32 rate;

	if (optlen < sizeof(rate))
		return -EINVAL;

#ifdef _LINUX_SOCKPTR_H
	if (copy_from_sockptr(&rate, optval, sizeof(rate)))
#else
	if (copy_from_user(&rate, optval, sizeof(rate)))
#endif
		return -EFAULT;

	ca->rate = rate;
	return 0;
}

#ifdef _LINUX_SOCKPTR_H
static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname,
				 sockptr_t optval, unsigned int optlen)
#else
static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname,
				 char __user *optval, unsigned int optlen)
#endif
{
	if (level == IPPROTO_TCP && optname == TCP_BRUTAL_RATE)
		return brutal_set_rate(sk, optval, optlen);

	/* 其余选项交还原始 TCP 处理 */
	return tcp_prot.setsockopt(sk, level, optname, optval, optlen);
}

/* ---- 拥塞控制回调 ---- */

static void brutal_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *ca = brutal_ca(sk);

	ca->rate = 0;
	tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;

	/* 覆盖 proto 以拦截 setsockopt(TCP_BRUTAL_RATE)(仅 IPv4) */
	if (sk->sk_family == AF_INET)
		sk->sk_prot = &tcp_prot_override;
	/* IPv6 拦截需额外扩展(参考上游 brutal >=5.8)，此处仅算法生效 */

	/* 默认启用 ECN 协商 */
	tp->ecn_flags |= TCP_ECN_OK;

	/* 启用内核内部 pacing(4.13+)，使基于速率的发送更平滑 */
	cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
}

/* cong_control: 4.19 在每次 ACK 时调用，覆盖默认 cong_avoid */
static void brutal_main(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *ca = brutal_ca(sk);
	u32 rtt_us, mss;
	u64 cwnd64;

	/* 未设置目标速率时不干预(应用须显式 setsockopt 设定速率) */
	if (ca->rate == 0)
		return;

	/*
	 * RTT 估计: 优先使用 rate_sample->rtt_us，
	 * 无有效采样时回退到 srtt(srtt_us 按 8 缩放，需 >>3 还原微秒)。
	 * 参考 4.19 rate_sample 字段: delivered/interval_us/rtt_us/
	 * losses/is_app_limited。
	 */
	rtt_us = rs->rtt_us;
	if (rtt_us == 0)
		rtt_us = tp->srtt_us >> 3;
	if (rtt_us == 0)
		return;

	mss = tp->mss_cache;
	if (mss == 0)
		return;

	/*
	 * cwnd(包) = rate(字节/秒) * rtt(秒) / mss(字节)
	 * 拆分为两次 do_div，避免单次 32 位除数在 jumbo frame 时溢出。
	 */
	cwnd64 = (u64)ca->rate * rtt_us;
	do_div(cwnd64, USEC_PER_SEC);	/* -> rate * rtt_seconds(字节) */
	do_div(cwnd64, mss);		/* -> 包数 */

	if (cwnd64 < TCP_INIT_CWND)
		cwnd64 = TCP_INIT_CWND;

	/* 丢包不降速: 每次 ACK 直接设为目标窗口 */
	tp->snd_cwnd = min_t(u32, (u32)cwnd64, tp->snd_cwnd_clamp);
	if (tp->snd_ssthresh < tp->snd_cwnd)
		tp->snd_ssthresh = tp->snd_cwnd;

	/* 设置 pacing 速率为目标速率，实现基于速率的平滑发送 */
	if (sk->sk_max_pacing_rate == 0 ||
	    sk->sk_max_pacing_rate == ~0U)
		sk->sk_pacing_rate = ca->rate;
	else
		sk->sk_pacing_rate = min_t(u32, ca->rate,
					   sk->sk_max_pacing_rate);
}

/* 丢包时不降低: 返回当前窗口 */
static u32 brutal_ssthresh(struct sock *sk)
{
	return tcp_sk(sk)->snd_cwnd;
}

static u32 brutal_undo_cwnd(struct sock *sk)
{
	return tcp_sk(sk)->snd_cwnd;
}

/* 通过 inet_diag 导出状态(复用 vegas info 结构) */
static size_t brutal_get_info(struct sock *sk, u32 ext, int *attr,
			      union tcp_cc_info *info)
{
	struct brutal *ca = brutal_ca(sk);

	if (ext & (1 << (INET_DIAG_VEGASINFO - 1))) {
		info->vegas.tcpv_enabled = (ca->rate != 0);
		info->vegas.tcpv_rttcnt = 0;
		info->vegas.tcpv_rtt = 0;
		info->vegas.tcpv_minrtt = ca->rate;
		*attr = INET_DIAG_VEGASINFO;
		return sizeof(struct tcpvegas_info);
	}
	return 0;
}

static struct tcp_congestion_ops tcp_brutal_ops = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "brutal",
	.owner		= THIS_MODULE,
	.init		= brutal_init,
	.cong_control	= brutal_main,
	.ssthresh	= brutal_ssthresh,
	.undo_cwnd	= brutal_undo_cwnd,
	.get_info	= brutal_get_info,
};

static int __init brutal_register(void)
{
	/* 验证私有数据不超过 TCP_CA_PRIV_SIZE */
	BUILD_BUG_ON(sizeof(struct brutal) > TCP_CA_PRIV_SIZE);

	/* 克隆 tcp_prot 并替换 setsockopt，拦截 TCP_BRUTAL_RATE */
	tcp_prot_override = tcp_prot;
	tcp_prot_override.setsockopt = brutal_tcp_setsockopt;

	pr_info("TCP Brutal: 速率型拥塞控制已加载(4.19 兼容)\n");
	return tcp_register_congestion_control(&tcp_brutal_ops);
}

static void __exit brutal_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_brutal_ops);
	pr_info("TCP Brutal: 已卸载\n");
}

module_init(brutal_register);
module_exit(brutal_unregister);

MODULE_AUTHOR("Oblivionis-kernel project");
MODULE_DESCRIPTION("TCP Brutal rate-based congestion control (4.19 compat)");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0-4.19");
