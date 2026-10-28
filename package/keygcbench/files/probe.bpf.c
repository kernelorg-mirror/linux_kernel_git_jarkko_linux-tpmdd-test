// SPDX-License-Identifier: GPL-2.0-or-later
#define BPF_NO_KFUNC_PROTOTYPES
#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include "keygcbench.h"

#define READ_ONCE(x) (*(volatile typeof(x) *)&(x))
#define WRITE_ONCE(x, val) (*(volatile typeof(x) *)&(x) = (val))

__u64 gc_func;
__u32 active;
__u64 run_start_ns;
__u64 total_queued;
__u64 total_started;
__u64 total_ended;
struct keygc_stats stats;

SEC("raw_tp/workqueue_queue_work")
int handle_queue_work(struct bpf_raw_tracepoint_args *ctx)
{
	struct work_struct *work = (void *)ctx->args[2];
	work_func_t func = NULL;

	if (bpf_core_read(&func, sizeof(func), &work->func)) {
		if (READ_ONCE(active))
			__sync_fetch_and_add(&stats.errors, 1);
		return 0;
	}

	if ((__u64)func != READ_ONCE(gc_func))
		return 0;

	__sync_fetch_and_add(&total_queued, 1);
	if (READ_ONCE(active))
		__sync_fetch_and_add(&stats.queued, 1);

	return 0;
}

SEC("raw_tp/workqueue_execute_start")
int handle_execute_start(struct bpf_raw_tracepoint_args *ctx)
{
	struct work_struct *work = (void *)ctx->args[0];
	work_func_t func = NULL;
	__u64 now;

	if (bpf_core_read(&func, sizeof(func), &work->func)) {
		if (READ_ONCE(active))
			__sync_fetch_and_add(&stats.errors, 1);
		return 0;
	}

	if ((__u64)func != READ_ONCE(gc_func))
		return 0;

	now = bpf_ktime_get_ns();
	__sync_fetch_and_add(&total_started, 1);

	if (READ_ONCE(active)) {
		WRITE_ONCE(run_start_ns, now);
		__sync_fetch_and_add(&stats.started, 1);
	}

	return 0;
}

SEC("raw_tp/workqueue_execute_end")
int handle_execute_end(struct bpf_raw_tracepoint_args *ctx)
{
	__u64 start_ns, ns, lo, hi, p0, p1, p2, mid, sq_lo, sq_hi, new_lo;
	__u64 func = ctx->args[1];

	if (func != READ_ONCE(gc_func))
		return 0;

	if (READ_ONCE(active)) {
		start_ns = READ_ONCE(run_start_ns);
		WRITE_ONCE(run_start_ns, 0);

		if (!start_ns) {
			__sync_fetch_and_add(&stats.errors, 1);
		} else {
			ns = bpf_ktime_get_ns() - start_ns;
			lo = ns & 0xffffffffULL;
			hi = ns >> 32;
			p0 = lo * lo;
			p1 = lo * hi;
			p2 = hi * hi;
			mid = (p0 >> 32) + (p1 & 0xffffffffULL) +
			      (p1 & 0xffffffffULL);
			sq_lo = (p0 & 0xffffffffULL) | (mid << 32);
			sq_hi = p2 + (p1 >> 32) + (p1 >> 32) + (mid >> 32);
			new_lo = stats.sum_sq_lo + sq_lo;

			if (!stats.count || ns < stats.min_ns)
				stats.min_ns = ns;
			if (ns > stats.max_ns)
				stats.max_ns = ns;

			stats.total_ns += ns;
			stats.sum_sq_hi += sq_hi + (new_lo < stats.sum_sq_lo);
			stats.sum_sq_lo = new_lo;
			stats.count++;
		}

		__sync_fetch_and_add(&stats.ended, 1);
	}

	__sync_fetch_and_add(&total_ended, 1);
	return 0;
}

char LICENSE[] SEC("license") = "GPL";
