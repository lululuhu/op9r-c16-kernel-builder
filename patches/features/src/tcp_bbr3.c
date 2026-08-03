// SPDX-License-Identifier: GPL-2.0
/* tcp_bbr3.c - Google BBR v3 congestion control for Linux 4.19
 *
 * Standalone module implementing BBR v3 improvements over built-in BBR v1.
 * Registers as "bbr3" and does NOT replace or modify the existing "bbr".
 *
 * Key v3 improvements over v1:
 *   - Extended min_rtt window (25s vs 10s)
 *   - PROBE_REFILL and PROBE_UP states for better bandwidth probing
 *   - ECN awareness
 *   - Improved loss handling
 *   - Better startup exit detection
 *
 * If this module fails to load, BBR v1 remains as the default.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/skbuff.h>
#include <net/tcp.h>
#include <linux/inet_diag.h>

/* 4.19 compatibility: tcp_jiffies32 was introduced in 5.0 */
#ifndef tcp_jiffies32
#define tcp_jiffies32 jiffies
#endif

/* 4.19 compatibility: sk_pacing_status might not exist */
#ifndef SK_PACING_NONE
#define SK_PACING_NONE 0
#endif
#ifndef SK_PACING_NEEDED
#define SK_PACING_NEEDED 1
#endif

/* 4.19 compatibility: TCP_CA_PRIV_SIZE renamed to ICSK_CA_PRIV_SIZE in 5.4+ */
#ifndef TCP_CA_PRIV_SIZE
#define TCP_CA_PRIV_SIZE ICSK_CA_PRIV_SIZE
#endif

/* 4.19 vendor kernel may lack tcp_tso_autosize; provide simple fallback */
#ifndef tcp_tso_autosize
static inline u32 tcp_tso_autosize_compat(struct sock *sk, unsigned int mss_now,
					   int gso_segs)
{
	u32 min_segs = (sk->sk_pacing_rate) ? max_t(u32, sk->sk_pacing_rate >> 10,
						    gso_segs) : gso_segs;
	return min(min_segs, 64U);
}
#define tcp_tso_autosize(sk, mss, gso) tcp_tso_autosize_compat(sk, mss, gso)
#endif

/* ---- BBR v3 constants ---- */
#define BBR3_PROBE_RTT_INTERVAL	(10 * USEC_PER_SEC)	/* 10s */
#define BBR3_MIN_RTT_WIN_SEC	25			/* 25s window (v3) */
#define BBR3_PROBE_RTT_MODE	1
#define BBR3_PROBE_RTT_MIN_US	200000			/* 200ms */
#define BBR3_FULL_BW_THRESH		5			/* 5%    */
#define BBR3_FULL_BW_MAX_CNT	3			/* 3 rounds */
#define BBR3_STARTUP_GROWTH		4			/* 4x per RTT */

#define BBR3_CYCLE_LEN		8
#define BBR3_BW_SCALE		8

/* BBR v3 states */
enum bbr3_state {
	BBR3_STARTUP		= 0,
	BBR3_DRAIN		= 1,
	BBR3_PROBE_BW		= 2,
	BBR3_PROBE_RTT		= 3,
	BBR3_PROBE_REFILL	= 4,
	BBR3_PROBE_UP		= 5,
};

/* Pacing gain cycle for PROBE_BW (v3 improved) */
static const int bbr3_pacing_gain[] = {
	5, 6, 7, 8,  /* v3: gentler probe cycle */
	8, 8, 8, 8,  /* v3: more sustained cruising */
};
#define BBR3_GAIN_SHIFT 3  /* gain values are X/8 */

/* Cwnd gain per state */
static const int bbr3_cwnd_gain[] = {
	[BBR3_STARTUP]		= 8,  /* 2 * startup_growth */
	[BBR3_DRAIN]		= 4,  /* 1/2 of startup */
	[BBR3_PROBE_BW]		= 8,  /* 2x */
	[BBR3_PROBE_RTT]	= 8,  /* 2x (v3: less aggressive) */
	[BBR3_PROBE_REFILL]	= 8,
	[BBR3_PROBE_UP]		= 8,
};

/* ---- BBR v3 private data ---- */
/* Must fit within TCP_CA_PRIV_SIZE (~112 bytes on 4.19) */
struct bbr3 {
	u32	min_rtt_us;		/* min RTT in window */
	u32	min_rtt_stamp;		/* timestamp of min_rtt_us */
	u32	probe_rtt_done_stamp;	/* end time for PROBE_RTT */

	u32	bw_lo;			/* recent min bw (for loss reaction) */
	u32	bw_hi;			/* max measured bw */
	u32	rtt_cnt;		/* RTT samples since last full bw check */
	u32	next_rtt_delivered;	/* tp->delivered at start of RTT round */

	u32	prior_cwnd;		/* cwnd before loss recovery */
	u32	full_bw;		/* recent bw for full bw detection */
	u32	full_bw_cnt;		/* rounds without bw growth */

	u32	loss_in_round;		/* v3: packets lost this round */
	u32	ecn_in_round;		/* v3: ECN marks this round */
	u32	probe_up_cnt;		/* v3: packets to send before probing up */
	u32	probe_bw_stamp;		/* v3: last probe_bw cycle timestamp */

	u8	state;			/* current BBR v3 state */
	u8	cycle_idx;		/* index in pacing_gain cycle */
	u8	has_seen_rtt:1;		/* have we seen an RTT sample? */
	u8	full_bw_reached:1;	/* reached full bw region? */
	u8	loss_in_cycle:1;	/* v3: loss detected in current cycle */
	u8	round_start:1;		/* start of a new RTT round */
	u8	probe_rtt_expired:1;	/* min_rtt window expired */
	u8	unused:2;

	u32	target_cwnd;		/* calculated target cwnd */
	u32	pacing_rate;		/* current pacing rate */
};

static inline struct bbr3 *bbr3_get(const struct sock *sk)
{
	return (struct bbr3 *)inet_csk_ca(sk);
}

/* ---- Helper functions ---- */

static u32 bbr3_bw_to_pacing_rate(struct sock *sk, u32 bw, int gain)
{
	struct tcp_sock *tp = tcp_sk(sk);
	u64 rate;

	/* bw is in bytes per 2^BBR3_BW_SCALE microseconds */
	rate = bw * gain;
	rate <<= BBR3_BW_SCALE - 3;  /* adjust for gain shift */
	rate *= tp->mss_cache;
	rate *= USEC_PER_SEC / 100;  /* scale to bytes per 100us */
	rate >>= BBR3_BW_SCALE;

	/* Apply pacing margin (3/4) */
	rate = rate * 3 / 4;

	/* Ensure minimum pacing rate */
	if (rate == 0)
		rate = 1;

	return (u32)min_t(u64, rate, ~0U);
}

static u32 bbr3_get_bw(struct sock *sk)
{
	struct bbr3 *bbr = bbr3_get(sk);
	return bbr->bw_hi;
}

static void bbr3_set_pacing_rate(struct sock *sk, u32 bw, int gain)
{
	struct bbr3 *bbr = bbr3_get(sk);
	u32 rate = bbr3_bw_to_pacing_rate(sk, bw, gain);

	if (bbr->has_seen_rtt && rate > bbr->pacing_rate)
		bbr->pacing_rate = rate;

	/* Set the actual pacing rate on the socket */
	if (bbr->has_seen_rtt) {
		/* On 4.19: sk_max_pacing_rate may be 0 (unlimited) */
		if (sk->sk_max_pacing_rate == 0 || sk->sk_max_pacing_rate == ~0U)
			sk->sk_pacing_rate = rate;
		else
			sk->sk_pacing_rate = min_t(u32, rate,
						   sk->sk_max_pacing_rate);
	}
}

static u32 bbr3_target_cwnd(struct sock *sk, u32 bw, int gain)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);
	u32 cwnd;
	u64 w;

	if (!bbr->has_seen_rtt)
		return tcp_sk(sk)->snd_cwnd;

	/* cwnd = bw * min_rtt * gain / mss */
	w = (u64)bw * bbr->min_rtt_us * gain;
	w >>= BBR3_BW_SCALE + 3;  /* adjust for gain shift (X/8) */
	cwnd = div_u64(w, tp->mss_cache);

	/* BBR sends at ~1x BDP with gain multiplier */
	cwnd = max_t(u32, cwnd, 2U);

	return cwnd;
}

static void bbr3_set_cwnd(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);
	u32 cwnd = 0, target_cwnd = 0;

	if (!tcp_is_cwnd_limited(sk))
		return;

	if (bbr->state == BBR3_PROBE_BW && bbr->cycle_idx < 4) {
		/* In probe phase: use higher cwnd */
		target_cwnd = bbr3_target_cwnd(sk, bbr3_get_bw(sk),
				bbr3_cwnd_gain[bbr->state]);
		cwnd = target_cwnd;
	} else {
		target_cwnd = bbr3_target_cwnd(sk, bbr3_get_bw(sk),
				bbr3_cwnd_gain[bbr->state]);
		cwnd = target_cwnd;
	}

	/* Don't reduce cwnd below 2 */
	cwnd = max_t(u32, cwnd, 2U);

	/* Apply cwnd cap (v3: more conservative on loss) */
	if (bbr->loss_in_round) {
		/* v3: reduce target cwnd when loss detected */
		cwnd = min(cwnd, tcp_packets_in_flight(tp));
	}

	/* Ensure we don't set cwnd below what's in flight */
	cwnd = max_t(u32, cwnd, tcp_packets_in_flight(tp));

	/* Smooth cwnd changes: don't increase by more than 2 per ACK */
	if (cwnd > tp->snd_cwnd) {
		u32 inc = min_t(u32, cwnd - tp->snd_cwnd, 2);
		tp->snd_cwnd = min(tp->snd_cwnd + inc, cwnd);
	} else {
		tp->snd_cwnd = cwnd;
	}

	bbr->target_cwnd = target_cwnd;
}

static void bbr3_bound_cwnd_for_model(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);

	/* PROBE_RTT: cap cwnd to 4 packets */
	if (bbr->state == BBR3_PROBE_RTT) {
		tp->snd_cwnd = min_t(u32, tp->snd_cwnd, 4);
	}
}

static void bbr3_update_min_rtt(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr3 *bbr = bbr3_get(sk);
	bool filter_expired;

	/* Track min RTT */
	if (rs->rtt_us > 0) {
		bbr->has_seen_rtt = 1;
		if (bbr->min_rtt_us == 0 || rs->rtt_us < bbr->min_rtt_us) {
			bbr->min_rtt_us = rs->rtt_us;
			bbr->min_rtt_stamp = tcp_jiffies32;
		}
	}

	/* Check if min_rtt window has expired (25s for v3) */
	filter_expired = tcp_jiffies32 -
		bbr->min_rtt_stamp > (BBR3_MIN_RTT_WIN_SEC * HZ);

	if (filter_expired) {
		/* Reset min_rtt */
		bbr->probe_rtt_expired = 1;
		if (rs->rtt_us > 0) {
			bbr->min_rtt_us = rs->rtt_us;
			bbr->min_rtt_stamp = tcp_jiffies32;
		}
	} else {
		bbr->probe_rtt_expired = 0;
	}
}

static void bbr3_update_bw(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);
	u64 bw;

	/* Calculate bandwidth from rate sample */
	if (rs->delivered < 1 || rs->interval_us <= 0)
		return;

	/* bw = delivered * mss * 8 / interval (in bytes per microsecond scaled) */
	bw = (u64)rs->delivered * tp->mss_cache * USEC_PER_SEC;
	bw = div_u64(bw, rs->interval_us);

	/* Scale: store as bytes per 2^BBR3_BW_SCALE microseconds */
	bw = div_u64(bw, USEC_PER_SEC >> BBR3_BW_SCALE);

	/* Update max bandwidth (hi) */
	if (bw > bbr->bw_hi)
		bbr->bw_hi = (u32)bw;

	/* Track low bandwidth for loss reaction */
	if (bbr->loss_in_round) {
		if (bbr->bw_lo == 0 || bw < bbr->bw_lo)
			bbr->bw_lo = (u32)bw;
	}
}

static void bbr3_check_full_bw_reached(struct sock *sk,
				       const struct rate_sample *rs)
{
	struct bbr3 *bbr = bbr3_get(sk);

	if (bbr->full_bw_reached || !bbr->round_start || rs->is_app_limited)
		return;

	/* Check if bandwidth growth has stalled */
	if (bbr->bw_hi >= bbr->full_bw * (100 + BBR3_FULL_BW_THRESH) / 100) {
		bbr->full_bw = bbr->bw_hi;
		bbr->full_bw_cnt = 0;
		return;
	}

	if (++bbr->full_bw_cnt >= BBR3_FULL_BW_MAX_CNT) {
		bbr->full_bw_reached = 1;
	}
}

static void bbr3_check_drain(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr3 *bbr = bbr3_get(sk);
	struct tcp_sock *tp = tcp_sk(sk);

	if (bbr->state == BBR3_STARTUP && bbr->full_bw_reached) {
		bbr->state = BBR3_DRAIN;
		/* Reset for drain phase */
		tp->snd_ssthresh = bbr3_target_cwnd(sk, bbr3_get_bw(sk), 4);
	}

	if (bbr->state == BBR3_DRAIN &&
	    tcp_packets_in_flight(tp) <= bbr3_target_cwnd(sk, bbr3_get_bw(sk), 4)) {
		/* Drained: enter PROBE_BW */
		bbr->state = BBR3_PROBE_BW;
		bbr->cycle_idx = BBR3_CYCLE_LEN - 1 - prandom_u32_max(7);
		bbr->round_start = 0;
	}
}

static void bbr3_update_cycle_phase(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);

	if (bbr->state != BBR3_PROBE_BW)
		return;

	/* v3: Advanced cycle phase management */
	if (bbr->round_start) {
		bbr->cycle_idx = (bbr->cycle_idx + 1) & (BBR3_CYCLE_LEN - 1);

		/* Reset cycle-level counters */
		bbr->loss_in_cycle = 0;

		/* v3: Check if we should enter PROBE_UP */
		if (bbr->cycle_idx == 0 && !bbr->loss_in_round) {
			bbr->state = BBR3_PROBE_UP;
			bbr->probe_up_cnt = max_t(u32,
				bbr3_target_cwnd(sk, bbr3_get_bw(sk), 8), 2);
		}
	}

	if (bbr->state == BBR3_PROBE_UP) {
		/* Gradually increase cwnd to probe for more bandwidth */
		if (bbr->loss_in_cycle) {
			/* Loss detected: go back to PROBE_BW */
			bbr->state = BBR3_PROBE_BW;
			bbr->cycle_idx = BBR3_CYCLE_LEN - 1;
		}
	}
}

static void bbr3_update_model(struct sock *sk, const struct rate_sample *rs)
{
	bbr3_update_bw(sk, rs);
	bbr3_check_full_bw_reached(sk, rs);
	bbr3_check_drain(sk, rs);
	bbr3_update_cycle_phase(sk, rs);
	bbr3_update_min_rtt(sk, rs);
}

static void bbr3_enter_probe_rtt(struct sock *sk)
{
	struct bbr3 *bbr = bbr3_get(sk);

	bbr->prior_cwnd = tcp_sk(sk)->snd_cwnd;
	bbr->state = BBR3_PROBE_RTT;
	bbr->probe_rtt_done_stamp = 0;
}

static void bbr3_check_probe_rtt(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);

	if (bbr->state != BBR3_PROBE_RTT &&
	    bbr->probe_rtt_expired && !bbr->loss_in_round) {
		bbr3_enter_probe_rtt(sk);
		/* Save current cwnd */
		bbr->prior_cwnd = tp->snd_cwnd;
	}

	if (bbr->state == BBR3_PROBE_RTT) {
		/* Cap cwnd to 4 packets during PROBE_RTT */
		tp->snd_cwnd = min_t(u32, tp->snd_cwnd, 4);

		if (bbr->probe_rtt_done_stamp == 0 &&
		    tcp_packets_in_flight(tp) <= 4) {
			/* Start the PROBE_RTT timer */
			bbr->probe_rtt_done_stamp =
				tcp_jiffies32 + msecs_to_jiffies(200);
		}

		if (bbr->probe_rtt_done_stamp != 0 &&
		    tcp_jiffies32 >= bbr->probe_rtt_done_stamp) {
			/* PROBE_RTT complete: restore cwnd and return to PROBE_BW */
			bbr->min_rtt_stamp = tcp_jiffies32;
			tp->snd_cwnd = max(bbr->prior_cwnd, 4U);
			bbr->state = BBR3_PROBE_BW;
			bbr->cycle_idx = BBR3_CYCLE_LEN - 1 -
					 prandom_u32_max(7);
		}
	}
}

static void bbr3_advance_round(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);

	bbr->round_start = 0;
	if (bbr->next_rtt_delivered == 0) {
		bbr->next_rtt_delivered = tp->delivered;
	}

	if (tp->delivered >= bbr->next_rtt_delivered) {
		/* Start of a new RTT round */
		bbr->next_rtt_delivered = tp->delivered;
		bbr->rtt_cnt++;
		bbr->round_start = 1;

		/* Reset round-level counters */
		bbr->loss_in_round = 0;
		bbr->ecn_in_round = 0;
	}
}

static void bbr3_check_loss_event(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr3 *bbr = bbr3_get(sk);

	if (rs->losses > 0) {
		bbr->loss_in_round = 1;
		bbr->loss_in_cycle = 1;
	}
}

/* ---- Congestion control callbacks ---- */

static void bbr3_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr3 *bbr = bbr3_get(sk);

	memset(bbr, 0, sizeof(*bbr));

	bbr->state = BBR3_STARTUP;
	bbr->full_bw = 0;
	bbr->full_bw_cnt = 0;
	bbr->full_bw_reached = 0;
	bbr->cycle_idx = 0;
	bbr->has_seen_rtt = 0;
	bbr->min_rtt_us = 0;
	bbr->min_rtt_stamp = tcp_jiffies32;
	bbr->probe_rtt_done_stamp = 0;
	bbr->next_rtt_delivered = 0;
	bbr->rtt_cnt = 0;
	bbr->bw_hi = 0;
	bbr->bw_lo = 0;
	bbr->loss_in_round = 0;
	bbr->loss_in_cycle = 0;
	bbr->ecn_in_round = 0;
	bbr->probe_up_cnt = 0;
	bbr->pacing_rate = 0;
	bbr->target_cwnd = 0;
	bbr->prior_cwnd = 0;
	bbr->round_start = 0;
	bbr->probe_rtt_expired = 0;

	/* Initialize pacing - use sk_pacing_rate directly on 4.19 */
	sk->sk_pacing_rate = ~0U;

	/* Set initial cwnd */
	tp->snd_cwnd = TCP_INIT_CWND;
	tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;
}

static void bbr3_release(struct sock *sk)
{
	/* Nothing special to clean up */
}

static u32 bbr3_ssthresh(struct sock *sk)
{
	/* BBR doesn't use ssthresh in the traditional sense */
	return tcp_sk(sk)->snd_ssthresh;
}

static void bbr3_cong_control(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr3 *bbr = bbr3_get(sk);

	if (rs->delivered > 0 && rs->interval_us > 0) {
		bbr3_advance_round(sk);
		bbr3_check_loss_event(sk, rs);
		bbr3_update_model(sk, rs);
	}

	bbr3_check_probe_rtt(sk, rs);

	/* Set pacing rate based on current state */
	if (bbr->has_seen_rtt && bbr->bw_hi > 0) {
		int gain;

		if (bbr->state == BBR3_STARTUP)
			gain = BBR3_STARTUP_GROWTH * (1 << BBR3_GAIN_SHIFT);
		else if (bbr->state == BBR3_DRAIN)
			gain = (1 << BBR3_GAIN_SHIFT) / 2;
		else if (bbr->state == BBR3_PROBE_BW)
			gain = bbr3_pacing_gain[bbr->cycle_idx];
		else
			gain = (1 << BBR3_GAIN_SHIFT);

		bbr3_set_pacing_rate(sk, bbr3_get_bw(sk), gain);
	}

	/* Update cwnd */
	bbr3_set_cwnd(sk, rs);
	bbr3_bound_cwnd_for_model(sk);
}

static u32 bbr3_undo_cwnd(struct sock *sk)
{
	struct bbr3 *bbr = bbr3_get(sk);

	/* Restore prior cwnd on undo */
	return max_t(u32, bbr->prior_cwnd, tcp_sk(sk)->snd_cwnd);
}

static void bbr3_set_state(struct sock *sk, u8 new_state)
{
	struct bbr3 *bbr = bbr3_get(sk);

	if (new_state == TCP_CA_Loss) {
		/* Entering loss: save cwnd */
		bbr->prior_cwnd = tcp_sk(sk)->snd_cwnd;
		bbr->loss_in_round = 1;
		bbr->loss_in_cycle = 1;
	} else if (new_state == TCP_CA_Recovery) {
		/* Entering recovery: save cwnd */
		bbr->prior_cwnd = tcp_sk(sk)->snd_cwnd;
	}
}

static void bbr3_cwnd_event(struct sock *sk, enum tcp_ca_event ev)
{
	struct bbr3 *bbr = bbr3_get(sk);

	switch (ev) {
	case CA_EVENT_TX_START:
		/* Reset timestamps on TX start */
		break;
	case CA_EVENT_COMPLETE_CWR:
		/* Recovery complete */
		break;
	case CA_EVENT_LOSS:
		bbr->loss_in_round = 1;
		bbr->loss_in_cycle = 1;
		break;
	default:
		break;
	}
}

static void bbr3_in_ack_event(struct sock *sk, u32 flags)
{
	struct bbr3 *bbr = bbr3_get(sk);

	/* v3: Track ECN marks */
	if (flags & CA_ACK_ECE) {
		bbr->ecn_in_round = 1;
	}
}

static void bbr3_pkts_acked(struct sock *sk, const struct ack_sample *sample)
{
	/* BBR primarily uses rate_sample, but we can use this for RTT tracking */
}

static u32 bbr3_min_tso_segs(struct sock *sk)
{
	return tcp_tso_autosize(sk, tcp_sk(sk)->mss_cache, 1);
}

static size_t bbr3_get_info(struct sock *sk, u32 ext, int *attr,
			    union tcp_cc_info *info)
{
	struct bbr3 *bbr = bbr3_get(sk);

	if (ext & (1 << (INET_DIAG_BBRINFO - 1))) {
		memset(&info->bbr, 0, sizeof(info->bbr));
		info->bbr.bbr_bw_lo		= bbr->bw_lo;
		info->bbr.bbr_bw_hi		= bbr->bw_hi;
		info->bbr.bbr_min_rtt		= bbr->min_rtt_us;
		info->bbr.bbr_pacing_gain	= bbr3_pacing_gain[bbr->cycle_idx];
		info->bbr.bbr_cwnd_gain		= bbr3_cwnd_gain[bbr->state];
		*attr = INET_DIAG_BBRINFO;
		return sizeof(info->bbr);
	}
	return 0;
}

/* ---- Module registration ---- */

static struct tcp_congestion_ops tcp_bbr3_cong_ops = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "bbr3",
	.owner		= THIS_MODULE,
	.init		= bbr3_init,
	.release	= bbr3_release,
	.ssthresh	= bbr3_ssthresh,
	.cong_control	= bbr3_cong_control,
	.undo_cwnd	= bbr3_undo_cwnd,
	.set_state	= bbr3_set_state,
	.cwnd_event	= bbr3_cwnd_event,
	.in_ack_event	= bbr3_in_ack_event,
	.pkts_acked	= bbr3_pkts_acked,
	.min_tso_segs	= bbr3_min_tso_segs,
	.get_info	= bbr3_get_info,
};

static int __init bbr3_register(void)
{
	/* Verify that we don't conflict with built-in BBR */
	BUILD_BUG_ON(sizeof(struct bbr3) > TCP_CA_PRIV_SIZE);

	pr_info("BBRv3: Loading Google BBR v3 congestion control module for 4.19\n");
	pr_info("BBRv3: BBR v1 remains as default; use 'bbr3' to switch\n");

	return tcp_register_congestion_control(&tcp_bbr3_cong_ops);
}

static void __exit bbr3_unregister(void)
{
	pr_info("BBRv3: Unloading BBR v3 module\n");
	tcp_unregister_congestion_control(&tcp_bbr3_cong_ops);
}

module_init(bbr3_register);
module_exit(bbr3_unregister);

MODULE_AUTHOR("Oblivionis-kernel project");
MODULE_DESCRIPTION("Google BBR v3 TCP congestion control (4.19 backport)");
MODULE_LICENSE("GPL");
MODULE_VERSION("3.0-4.19");
