/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGC_BENCH_H
#define KEYGC_BENCH_H

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include "keygcbench.h"

#define KEYGC_TIMEOUT_SEC 600
#define KEYGC_LOAD_WORKERS 6

extern volatile sig_atomic_t keygc_interrupted;

struct keygc_population {
	int32_t ring_ids[6];
	int32_t trigger_key;
	unsigned long baseline;
	unsigned long keys[2];
	unsigned long saved_gc_delay;
	bool delay_changed;
};

int keygc_population_init(struct keygc_population *pop);
int keygc_population_trigger(struct keygc_population *pop, int phase);
int keygc_population_verify(const struct keygc_population *pop, int phase);
int keygc_population_cleanup(struct keygc_population *pop);
int keygc_count_read(unsigned long *count);

struct keygc_load {
	pid_t pids[KEYGC_LOAD_WORKERS];
};

int keygc_load_start(struct keygc_load *load);
int keygc_load_verify(const struct keygc_load *load);
int keygc_load_stop(struct keygc_load *load);

#endif /* KEYGC_BENCH_H */
