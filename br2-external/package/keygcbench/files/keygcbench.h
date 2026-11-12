/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGCBENCH_H
#define KEYGCBENCH_H

#ifndef __VMLINUX_H__
#include <stdint.h>
#endif

#define KEYGC_CPU 0

struct keygc_stats {
	uint64_t queued;
	uint64_t started;
	uint64_t ended;
	uint64_t errors;
	uint64_t count;
	uint64_t total_ns;
	uint64_t min_ns;
	uint64_t max_ns;
	uint64_t sum_sq_lo;
	uint64_t sum_sq_hi;
};

#endif /* KEYGCBENCH_H */
