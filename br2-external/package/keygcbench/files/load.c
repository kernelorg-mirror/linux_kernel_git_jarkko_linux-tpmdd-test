// SPDX-License-Identifier: GPL-2.0-or-later
#define _GNU_SOURCE
#include <errno.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "bench.h"

#define KEYGC_BUFFER_SIZE (64UL * 1024 * 1024)
#define KEYGC_MEMCPY_WORKERS 4

struct worker_state {
	unsigned long long ticks;
	unsigned long long faults;
	unsigned long long rss_kb;
};

static int worker_state_read(pid_t pid, struct worker_state *state)
{
	unsigned long long minflt, majflt, utime, stime;
	char path[64], line[4096], *comm_end;
	FILE *file;
	char task_state;

	snprintf(path, sizeof(path), "/proc/%d/stat", pid);
	file = fopen(path, "re");
	if (!file) {
		perror(path);
		return -1;
	}

	if (!fgets(line, sizeof(line), file)) {
		if (ferror(file))
			perror(path);
		else
			fprintf(stderr, "%s: unexpected EOF\n", path);
		fclose(file);
		return -1;
	}

	if (fclose(file)) {
		perror(path);
		return -1;
	}

	comm_end = strrchr(line, ')');
	if (!comm_end ||
	    sscanf(comm_end + 1,
		   " %c %*d %*d %*d %*d %*d %*u %llu %*u %llu %*u %llu %llu",
		   &task_state, &minflt, &majflt, &utime, &stime) != 5) {
		fprintf(stderr, "%s: failed to parse worker state\n", path);
		return -1;
	}

	if (task_state != 'R' && task_state != 'S' && task_state != 'D') {
		fprintf(stderr, "worker %d unexpected state '%c'\n",
			pid, task_state);
		return -1;
	}

	state->ticks = utime + stime;
	state->faults = minflt + majflt;
	state->rss_kb = 0;

	snprintf(path, sizeof(path), "/proc/%d/status", pid);
	file = fopen(path, "re");
	if (!file) {
		perror(path);
		return -1;
	}

	while (fgets(line, sizeof(line), file)) {
		if (sscanf(line, "VmRSS: %llu kB", &state->rss_kb) == 1)
			break;
	}

	if (ferror(file)) {
		perror(path);
		fclose(file);
		return -1;
	}

	if (fclose(file)) {
		perror(path);
		return -1;
	}

	return 0;
}

int keygc_load_start(struct keygc_load *load)
{
	unsigned long long min_kb = 2 * KEYGC_MEMCPY_WORKERS * 2 *
				    KEYGC_BUFFER_SIZE / 1024;
	struct worker_state prev[KEYGC_LOAD_WORKERS], cur[KEYGC_LOAD_WORKERS];
	unsigned long long stable_ticks[KEYGC_LOAD_WORKERS];
	struct timespec start, now, pause = { .tv_nsec = 100000000 };
	unsigned long long avail_kb = 0;
	sigset_t blocked, saved;
	pid_t pid, parent = getpid();
	bool found = false, ready;
	char line[256];
	FILE *file;
	int i;

	memset(load, 0, sizeof(*load));

	file = fopen("/proc/meminfo", "re");
	if (!file) {
		perror("/proc/meminfo");
		return -1;
	}

	while (fgets(line, sizeof(line), file)) {
		if (sscanf(line, "MemAvailable: %llu kB", &avail_kb) == 1) {
			found = true;
			break;
		}
	}

	if (ferror(file)) {
		perror("/proc/meminfo");
		fclose(file);
		return -1;
	}

	if (fclose(file)) {
		perror("/proc/meminfo");
		return -1;
	}

	if (!found || avail_kb < min_kb) {
		fprintf(stderr, "insufficient MemAvailable: %llu kB (need %llu kB)\n",
			avail_kb, min_kb);
		return -1;
	}

	sigemptyset(&blocked);
	sigaddset(&blocked, SIGTERM);
	sigaddset(&blocked, SIGINT);
	if (sigprocmask(SIG_BLOCK, &blocked, &saved)) {
		perror("sigprocmask");
		return -1;
	}

	for (i = 0; i < KEYGC_LOAD_WORKERS; i++) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			sigprocmask(SIG_SETMASK, &saved, NULL);
			goto err;
		}

		pid = fork();
		if (pid < 0) {
			perror("fork");
			sigprocmask(SIG_SETMASK, &saved, NULL);
			goto err;
		}

		if (!pid) {
			struct sigaction sa = { .sa_handler = SIG_DFL };

			sigemptyset(&sa.sa_mask);
			if (sigaction(SIGTERM, &sa, NULL) ||
			    sigaction(SIGINT, &sa, NULL) ||
			    sigprocmask(SIG_SETMASK, &saved, NULL) ||
			    prctl(PR_SET_PDEATHSIG, SIGTERM) ||
			    getppid() != parent)
				_exit(EXIT_FAILURE);

			if (i < KEYGC_MEMCPY_WORKERS) {
				void *src, *dst;

				src = mmap(NULL, KEYGC_BUFFER_SIZE,
					   PROT_READ | PROT_WRITE,
					   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
				dst = mmap(NULL, KEYGC_BUFFER_SIZE,
					   PROT_READ | PROT_WRITE,
					   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
				if (src == MAP_FAILED || dst == MAP_FAILED) {
					perror("mmap");
					_exit(EXIT_FAILURE);
				}

				memset(src, 0x5a, KEYGC_BUFFER_SIZE);
				memset(dst, 0xa5, KEYGC_BUFFER_SIZE);

				for (;;) {
					memcpy(dst, src, KEYGC_BUFFER_SIZE);
					__asm__ __volatile__("" : : "r" (src),
							     "r" (dst) : "memory");
				}
			} else {
				unsigned char buf[4096] = {};
				unsigned char md[EVP_MAX_MD_SIZE];
				unsigned int md_len;
				EVP_MD_CTX *ctx;

				ctx = EVP_MD_CTX_new();
				if (!ctx) {
					fputs("EVP_MD_CTX_new failed\n", stderr);
					_exit(EXIT_FAILURE);
				}

				while (EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) &&
				       EVP_DigestUpdate(ctx, buf, sizeof(buf)) &&
				       EVP_DigestFinal_ex(ctx, md, &md_len))
					;

				fputs("SHA-256 digest failed\n", stderr);
				EVP_MD_CTX_free(ctx);
				_exit(EXIT_FAILURE);
			}
		}

		load->pids[i] = pid;
	}

	if (sigprocmask(SIG_SETMASK, &saved, NULL)) {
		perror("sigprocmask");
		goto err;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &start)) {
		perror("clock_gettime");
		goto err;
	}

	for (i = 0; i < KEYGC_LOAD_WORKERS; i++) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			goto err;
		}

		if (worker_state_read(load->pids[i], &prev[i]))
			goto err;

		stable_ticks[i] = prev[i].ticks;
	}

	for (;;) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			goto err;
		}

		if (clock_gettime(CLOCK_MONOTONIC, &now)) {
			perror("clock_gettime");
			goto err;
		}

		if (now.tv_sec - start.tv_sec > KEYGC_TIMEOUT_SEC ||
		    (now.tv_sec - start.tv_sec == KEYGC_TIMEOUT_SEC &&
		     now.tv_nsec >= start.tv_nsec)) {
			fputs("timed out waiting for load workers to warm up\n",
			      stderr);
			goto err;
		}

		if (nanosleep(&pause, NULL)) {
			perror("nanosleep");
			goto err;
		}

		ready = true;
		for (i = 0; i < KEYGC_LOAD_WORKERS; i++) {
			if (keygc_interrupted) {
				fputs("interrupted\n", stderr);
				goto err;
			}

			if (worker_state_read(load->pids[i], &cur[i]))
				goto err;

			if (cur[i].faults != prev[i].faults ||
			    (i < KEYGC_MEMCPY_WORKERS &&
			     cur[i].rss_kb < 2 * KEYGC_BUFFER_SIZE / 1024))
				stable_ticks[i] = cur[i].ticks;

			if (cur[i].ticks < stable_ticks[i] ||
			    cur[i].ticks - stable_ticks[i] < 10)
				ready = false;

			prev[i] = cur[i];
		}

		if (ready)
			break;
	}

	return 0;

err:
	keygc_load_stop(load);
	return -1;
}

int keygc_load_verify(const struct keygc_load *load)
{
	struct worker_state state;
	int i;

	for (i = 0; i < KEYGC_LOAD_WORKERS; i++) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			return -1;
		}

		if (worker_state_read(load->pids[i], &state))
			return -1;

		if (i < KEYGC_MEMCPY_WORKERS &&
		    state.rss_kb < 2 * KEYGC_BUFFER_SIZE / 1024) {
			fprintf(stderr, "worker %d resident memory dropped to %llu kB\n",
				load->pids[i], state.rss_kb);
			return -1;
		}
	}

	return 0;
}

static int worker_reap(pid_t pid, unsigned int timeout_sec, int *status,
		       bool *timed_out)
{
	struct timespec start, now, pause = { .tv_nsec = 10000000 };
	pid_t ret;

	*timed_out = false;
	if (clock_gettime(CLOCK_MONOTONIC, &start)) {
		perror("clock_gettime");
		return -1;
	}

	for (;;) {
		ret = waitpid(pid, status, WNOHANG);
		if (ret == pid)
			return 0;
		if (ret < 0 && errno != EINTR) {
			perror("waitpid");
			return -1;
		}

		if (clock_gettime(CLOCK_MONOTONIC, &now)) {
			perror("clock_gettime");
			return -1;
		}

		if (now.tv_sec - start.tv_sec > timeout_sec ||
		    (now.tv_sec - start.tv_sec == timeout_sec &&
		     now.tv_nsec >= start.tv_nsec)) {
			*timed_out = true;
			return -1;
		}

		if (nanosleep(&pause, NULL) && errno != EINTR) {
			perror("nanosleep");
			return -1;
		}
	}
}

int keygc_load_stop(struct keygc_load *load)
{
	bool timed_out;
	int i, status, ret = 0;

	for (i = 0; i < KEYGC_LOAD_WORKERS; i++) {
		if (load->pids[i] > 0 && kill(load->pids[i], SIGTERM) &&
		    errno != ESRCH) {
			perror("kill");
			ret = -1;
		}
	}

	for (i = 0; i < KEYGC_LOAD_WORKERS; i++) {
		if (load->pids[i] <= 0)
			continue;

		if (worker_reap(load->pids[i], KEYGC_TIMEOUT_SEC, &status,
				&timed_out)) {
			ret = -1;
			if (!timed_out) {
				if (errno == ECHILD)
					load->pids[i] = 0;
				continue;
			}

			fprintf(stderr, "worker %d ignored SIGTERM\n",
				load->pids[i]);
			if (kill(load->pids[i], SIGKILL) && errno != ESRCH)
				perror("kill");
			if (!worker_reap(load->pids[i], 5, &status, &timed_out) ||
			    (!timed_out && errno == ECHILD))
				load->pids[i] = 0;
			continue;
		}

		if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) {
			fprintf(stderr, "worker %d unexpected wait status %#x\n",
				load->pids[i], status);
			ret = -1;
		}

		load->pids[i] = 0;
	}

	return ret;
}
