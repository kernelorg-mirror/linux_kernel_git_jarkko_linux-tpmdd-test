// SPDX-License-Identifier: GPL-2.0-or-later
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "bench.h"
#include "keygcbench.h"
#include "probe.skel.h"

volatile sig_atomic_t keygc_interrupted;

static void sigint_handler(int signo)
{
	keygc_interrupted = signo;
}

static int monotonic_ns_read(uint64_t *now)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts)) {
		perror("clock_gettime");
		return -1;
	}

	*now = (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
	return 0;
}

static int poll_sleep(void)
{
	struct timespec delay = { .tv_nsec = 10000000 };

	if (keygc_interrupted) {
		fputs("interrupted\n", stderr);
		return -1;
	}

	if (nanosleep(&delay, NULL)) {
		perror("nanosleep");
		return -1;
	}

	return 0;
}

static int probe_drain_wait(struct probe_bpf *skel)
{
	uint64_t prev_ended = 0, now, deadline;
	bool have_prev = false;

	if (monotonic_ns_read(&now))
		return -1;

	deadline = now + (uint64_t)KEYGC_TIMEOUT_SEC * 1000000000ULL;

	for (;;) {
		uint64_t q = __atomic_load_n(&skel->bss->total_queued,
					     __ATOMIC_ACQUIRE);
		uint64_t s = __atomic_load_n(&skel->bss->total_started,
					     __ATOMIC_ACQUIRE);
		uint64_t e = __atomic_load_n(&skel->bss->total_ended,
					     __ATOMIC_ACQUIRE);

		if (q == s && s == e && have_prev && e == prev_ended)
			return 0;

		prev_ended = e;
		have_prev = true;

		if (monotonic_ns_read(&now))
			return -1;

		if (now >= deadline) {
			fputs("timed out waiting for GC workqueue to drain\n",
			      stderr);
			return -1;
		}

		if (poll_sleep())
			return -1;
	}
}

static int keygc_phase_run(struct probe_bpf *skel,
			   struct keygc_population *pop, int phase,
			   struct keygc_stats *out)
{
	unsigned long count, expected = pop->baseline +
					(phase == 0 ? 1 + pop->keys[1] : 0);
	struct bpf_program *prog;
	struct keygc_load load = {};
	uint64_t now, deadline;

	if (probe_drain_wait(skel))
		return -1;

	if (keygc_load_start(&load))
		return -1;

	memset(&skel->bss->stats, 0, sizeof(skel->bss->stats));
	skel->bss->run_start_ns = 0;
	__atomic_store_n(&skel->bss->active, 1, __ATOMIC_RELEASE);

	if (keygc_population_trigger(pop, phase))
		goto err_probe;

	if (monotonic_ns_read(&now))
		goto err_probe;

	deadline = now + (uint64_t)KEYGC_TIMEOUT_SEC * 1000000000ULL;

	for (;;) {
		if (keygc_count_read(&count))
			goto err_probe;

		if (count == expected)
			break;

		if (monotonic_ns_read(&now))
			goto err_probe;

		if (now >= deadline) {
			fprintf(stderr, "timed out waiting for GC (key count %lu, expected %lu)\n",
				count, expected);
			goto err_probe;
		}

		if (poll_sleep())
			goto err_probe;
	}

	if (probe_drain_wait(skel))
		goto err_probe;

	__atomic_store_n(&skel->bss->active, 0, __ATOMIC_RELEASE);
	*out = skel->bss->stats;

	if (keygc_population_verify(pop, phase) || keygc_load_verify(&load))
		goto err_load;

	if (!out->count || out->queued != out->started ||
	    out->started != out->ended || out->count != out->ended ||
	    out->errors || out->min_ns > out->max_ns) {
		fputs("inconsistent workqueue trace statistics\n", stderr);
		goto err_load;
	}

	bpf_object__for_each_program(prog, skel->obj) {
		struct bpf_prog_info info = {};
		uint32_t len = sizeof(info);

		if (bpf_prog_get_info_by_fd(bpf_program__fd(prog), &info, &len)) {
			perror("bpf_prog_get_info_by_fd");
			goto err_load;
		}

		if (info.recursion_misses) {
			fprintf(stderr, "%s: %" PRIu64 " recursive trace misses\n",
				bpf_program__name(prog),
				(uint64_t)info.recursion_misses);
			goto err_load;
		}
	}

	return keygc_load_stop(&load);

err_probe:
	__atomic_store_n(&skel->bss->active, 0, __ATOMIC_RELEASE);
err_load:
	keygc_load_stop(&load);
	return -1;
}

static int stats_row_print(const char *label, const struct keygc_stats *s)
{
	__uint128_t sum_sq = ((__uint128_t)s->sum_sq_hi << 64) | s->sum_sq_lo;
	__uint128_t total = s->total_ns;
	__uint128_t diff = sum_sq * s->count >= total * total ?
			   sum_sq * s->count - total * total : 0;
	double avg_ms = (double)s->total_ns / s->count / 1000000.0;
	double var_ms2 = (double)diff /
			 ((double)s->count * s->count * 1000000000.0 * 1000.0);

	if (printf("%-9s min=%.3f avg=%.3f max=%.3f var=%.3f\n", label,
		   s->min_ns / 1000000.0, avg_ms,
		   s->max_ns / 1000000.0, var_ms2) < 0) {
		perror("printf");
		return -1;
	}

	return 0;
}

int main(void)
{
	struct sigaction sa = { .sa_handler = sigint_handler };
	struct keygc_stats stats[2] = {}, combined = {};
	struct keygc_population pop = {};
	unsigned long long gc_addr = 0;
	char line[1024], sym[512], type;
	struct probe_bpf *skel = NULL;
	cpu_set_t affinity;
	bool found = false;
	uint64_t new_lo;
	char errbuf[128];
	FILE *kallsyms;
	int ret;

	if (geteuid()) {
		fputs("keygcbench must run as root\n", stderr);
		return EXIT_FAILURE;
	}

	CPU_ZERO(&affinity);
	CPU_SET(KEYGC_CPU, &affinity);
	if (sigemptyset(&sa.sa_mask) ||
	    sigaction(SIGINT, &sa, NULL) ||
	    sigaction(SIGTERM, &sa, NULL) ||
	    sigaction(SIGHUP, &sa, NULL) ||
	    sigaction(SIGPIPE, &sa, NULL) ||
	    sched_setaffinity(0, sizeof(affinity), &affinity)) {
		perror("initialize benchmark");
		return EXIT_FAILURE;
	}

	kallsyms = fopen("/proc/kallsyms", "re");
	if (!kallsyms) {
		perror("/proc/kallsyms");
		return EXIT_FAILURE;
	}

	while (fgets(line, sizeof(line), kallsyms)) {
		if (sscanf(line, "%llx %c %511s", &gc_addr, &type, sym) == 3 &&
		    !strcmp(sym, "key_garbage_collector")) {
			found = true;
			break;
		}
	}

	if (ferror(kallsyms)) {
		perror("/proc/kallsyms");
		fclose(kallsyms);
		return EXIT_FAILURE;
	}

	if (fclose(kallsyms)) {
		perror("/proc/kallsyms");
		return EXIT_FAILURE;
	}

	if (!found || !gc_addr) {
		fputs("failed to resolve key_garbage_collector in /proc/kallsyms\n",
		      stderr);
		return EXIT_FAILURE;
	}

	skel = probe_bpf__open_and_load();
	if (!skel) {
		perror("probe_bpf__open_and_load");
		return EXIT_FAILURE;
	}

	skel->bss->gc_func = gc_addr;
	ret = probe_bpf__attach(skel);
	if (ret < 0) {
		libbpf_strerror(ret, errbuf, sizeof(errbuf));
		fprintf(stderr, "probe_bpf__attach: %s\n", errbuf);
		goto err_skel;
	}

	if (keygc_population_init(&pop))
		goto err_skel;

	if (keygc_phase_run(skel, &pop, 0, &stats[0]) ||
	    keygc_phase_run(skel, &pop, 1, &stats[1]))
		goto err_pop;

	combined = stats[0];
	if (stats[1].min_ns < combined.min_ns)
		combined.min_ns = stats[1].min_ns;
	if (stats[1].max_ns > combined.max_ns)
		combined.max_ns = stats[1].max_ns;
	combined.total_ns += stats[1].total_ns;
	new_lo = combined.sum_sq_lo + stats[1].sum_sq_lo;
	combined.sum_sq_hi += stats[1].sum_sq_hi + (new_lo < combined.sum_sq_lo);
	combined.sum_sq_lo = new_lo;
	combined.count += stats[1].count;

	if (stats_row_print("unused:", &stats[0]) ||
	    stats_row_print("expired:", &stats[1]) ||
	    stats_row_print("combined:", &combined))
		goto err_pop;

	if (fflush(stdout)) {
		perror("fflush");
		goto err_pop;
	}

	probe_bpf__destroy(skel);
	if (keygc_population_cleanup(&pop))
		return EXIT_FAILURE;

	return EXIT_SUCCESS;

err_pop:
	keygc_population_cleanup(&pop);
err_skel:
	probe_bpf__destroy(skel);
	return EXIT_FAILURE;
}
