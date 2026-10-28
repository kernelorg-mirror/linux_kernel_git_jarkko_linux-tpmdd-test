// SPDX-License-Identifier: GPL-2.0-or-later
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/keyctl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include "bench.h"

#define KEYGC_DELAY_PATH "/proc/sys/kernel/keys/gc_delay"

static long sys_keyctl(unsigned long cmd, unsigned long arg2,
		       unsigned long arg3)
{
	return syscall(__NR_keyctl, cmd, arg2, arg3, 0UL, 0UL);
}

static long sys_add_key(const char *type, const char *desc,
			const void *payload, size_t plen, int32_t ring)
{
	return syscall(__NR_add_key, type, desc, payload, plen, ring);
}

static int gc_delay_write(unsigned long value)
{
	char text[32];
	ssize_t written;
	int fd, len, ret = 0;

	fd = open(KEYGC_DELAY_PATH, O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		perror(KEYGC_DELAY_PATH);
		return -1;
	}

	len = snprintf(text, sizeof(text), "%lu\n", value);
	written = write(fd, text, len);
	if (written < 0) {
		perror(KEYGC_DELAY_PATH);
		ret = -1;
	} else if (written != len) {
		fprintf(stderr, "%s: short write\n", KEYGC_DELAY_PATH);
		ret = -1;
	}

	if (close(fd) && !ret) {
		perror(KEYGC_DELAY_PATH);
		ret = -1;
	}

	return ret;
}

int keygc_count_read(unsigned long *count)
{
	unsigned long uid, refs, instantiated, charged, maxkeys, bytes, maxbytes;
	bool found = false;
	char line[256];
	FILE *file;
	int ret = 0;

	file = fopen("/proc/key-users", "re");
	if (!file) {
		perror("/proc/key-users");
		return -1;
	}

	while (fgets(line, sizeof(line), file)) {
		if (sscanf(line, "%lu: %lu %lu/%lu %lu/%lu %lu/%lu",
			   &uid, &refs, count, &instantiated,
			   &charged, &maxkeys, &bytes, &maxbytes) == 8 && !uid) {
			found = true;
			break;
		}
	}

	if (ferror(file)) {
		perror("/proc/key-users");
		ret = -1;
	}

	if (fclose(file) && !ret) {
		perror("/proc/key-users");
		ret = -1;
	}

	if (!ret && !found) {
		fputs("/proc/key-users: root entry not found\n", stderr);
		return -1;
	}

	return ret;
}

static int key_count_wait(unsigned long expected)
{
	struct timespec start, now, pause = { .tv_nsec = 100000000 };
	unsigned long count;

	if (clock_gettime(CLOCK_MONOTONIC, &start)) {
		perror("clock_gettime");
		return -1;
	}

	for (;;) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			return -1;
		}

		if (keygc_count_read(&count))
			return -1;

		if (count == expected)
			return 0;

		if (clock_gettime(CLOCK_MONOTONIC, &now)) {
			perror("clock_gettime");
			return -1;
		}

		if (now.tv_sec - start.tv_sec > KEYGC_TIMEOUT_SEC ||
		    (now.tv_sec - start.tv_sec == KEYGC_TIMEOUT_SEC &&
		     now.tv_nsec >= start.tv_nsec)) {
			fprintf(stderr, "timed out waiting for key count %lu (got %lu)\n",
				expected, count);
			return -1;
		}

		if (nanosleep(&pause, NULL)) {
			perror("nanosleep");
			return -1;
		}
	}
}

static int keyring_links_verify(const struct keygc_population *pop, int phase)
{
	unsigned long expected;
	long bytes;
	int i;

	for (i = 0; i < 6; i++) {
		expected = 0;
		if (phase < 0 || (phase == 0 && i % 2))
			expected = pop->keys[i % 2] / 3 +
				   ((unsigned int)i / 2 < pop->keys[i % 2] % 3);

		bytes = sys_keyctl(KEYCTL_READ, pop->ring_ids[i], 0);
		if (bytes < 0) {
			perror("keyctl(KEYCTL_READ)");
			return -1;
		}

		if ((unsigned long)bytes != expected * sizeof(int32_t)) {
			fprintf(stderr, "ring %d: %ld link bytes, expected %lu\n",
				pop->ring_ids[i], bytes,
				expected * (unsigned long)sizeof(int32_t));
			return -1;
		}
	}

	return 0;
}

int keygc_population_init(struct keygc_population *pop)
{
	struct timespec pause = { .tv_sec = 2 };
	char name[64];
	FILE *file;
	unsigned long idx;
	long key;
	int i, ring;

	memset(pop, 0, sizeof(*pop));

	if (sys_keyctl(KEYCTL_JOIN_SESSION_KEYRING, 0, 0) < 0) {
		perror("keyctl(KEYCTL_JOIN_SESSION_KEYRING)");
		return -1;
	}

	if (sys_keyctl(KEYCTL_GET_KEYRING_ID, KEY_SPEC_USER_KEYRING, 1) < 0 ||
	    sys_keyctl(KEYCTL_GET_KEYRING_ID,
		       KEY_SPEC_USER_SESSION_KEYRING, 1) < 0) {
		perror("keyctl(KEYCTL_GET_KEYRING_ID)");
		return -1;
	}

	file = fopen(KEYGC_DELAY_PATH, "re");
	if (!file) {
		perror(KEYGC_DELAY_PATH);
		return -1;
	}

	if (fscanf(file, "%lu", &pop->saved_gc_delay) != 1) {
		if (ferror(file))
			perror(KEYGC_DELAY_PATH);
		else
			fprintf(stderr, "%s: failed to parse value\n",
				KEYGC_DELAY_PATH);
		fclose(file);
		return -1;
	}

	if (fclose(file)) {
		perror(KEYGC_DELAY_PATH);
		return -1;
	}

	pop->delay_changed = true;
	if (gc_delay_write(86400))
		goto err;

	for (i = 0; i < 6; i++) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			goto err;
		}

		snprintf(name, sizeof(name), "keygc:ring:%d", i);
		key = sys_add_key("keyring", name, NULL, 0,
				  KEY_SPEC_SESSION_KEYRING);
		if (key < 0) {
			perror("add_key");
			goto err;
		}

		pop->ring_ids[i] = key;
	}

	if (keygc_count_read(&pop->baseline))
		goto err;

	key = sys_add_key("user", "keygc:warmup", "x", 1,
			  KEY_SPEC_SESSION_KEYRING);
	if (key < 0) {
		perror("add_key");
		goto err;
	}

	pop->trigger_key = key;
	if (sys_keyctl(KEYCTL_UNLINK, key, KEY_SPEC_SESSION_KEYRING) < 0) {
		perror("keyctl(KEYCTL_UNLINK)");
		goto err;
	}

	pop->trigger_key = 0;
	if (key_count_wait(pop->baseline))
		goto err;

	key = sys_add_key("user", "keygc:trigger", "x", 1,
			  KEY_SPEC_SESSION_KEYRING);
	if (key < 0) {
		perror("add_key");
		goto err;
	}

	pop->trigger_key = key;

	for (idx = 0; ; idx++) {
		if (keygc_interrupted) {
			fputs("interrupted\n", stderr);
			goto err;
		}

		ring = idx % 6;
		snprintf(name, sizeof(name), "keygc:%c:%08lx",
			 ring % 2 ? 'l' : 'u', pop->keys[ring % 2]);

		key = sys_add_key("user", name, "x", 1, pop->ring_ids[ring]);
		if (key < 0) {
			if (errno == EDQUOT)
				break;
			perror("add_key");
			goto err;
		}

		pop->keys[ring % 2]++;
		if (ring % 2 && sys_keyctl(KEYCTL_SET_TIMEOUT, key, 1) < 0) {
			perror("keyctl(KEYCTL_SET_TIMEOUT)");
			goto err;
		}
	}

	if (!pop->keys[0] || !pop->keys[1]) {
		fputs("key quota too small to populate both phases\n", stderr);
		goto err;
	}

	if (keygc_interrupted) {
		fputs("interrupted\n", stderr);
		goto err;
	}

	if (nanosleep(&pause, NULL)) {
		perror("nanosleep");
		goto err;
	}

	if (key_count_wait(pop->baseline + 1 + pop->keys[0] + pop->keys[1]) ||
	    keyring_links_verify(pop, -1))
		goto err;

	return 0;

err:
	keygc_population_cleanup(pop);
	return -1;
}

int keygc_population_trigger(struct keygc_population *pop, int phase)
{
	int i;

	if (keygc_interrupted) {
		fputs("interrupted\n", stderr);
		return -1;
	}

	if (!phase) {
		for (i = 0; i < 6; i += 2) {
			if (keygc_interrupted) {
				fputs("interrupted\n", stderr);
				return -1;
			}

			if (sys_keyctl(KEYCTL_CLEAR, pop->ring_ids[i], 0) < 0) {
				perror("keyctl(KEYCTL_CLEAR)");
				return -1;
			}
		}

		return 0;
	}

	if (gc_delay_write(0))
		return -1;

	if (sys_keyctl(KEYCTL_INVALIDATE, pop->trigger_key, 0) < 0) {
		perror("keyctl(KEYCTL_INVALIDATE)");
		return -1;
	}

	pop->trigger_key = 0;
	return 0;
}

int keygc_population_verify(const struct keygc_population *pop, int phase)
{
	unsigned long expected = pop->baseline +
				 (phase == 0 ? 1 + pop->keys[1] : 0);

	if (key_count_wait(expected))
		return -1;

	return keyring_links_verify(pop, phase);
}

int keygc_population_cleanup(struct keygc_population *pop)
{
	int i, ret = 0;

	for (i = 0; i < 6; i++) {
		if (!pop->ring_ids[i])
			continue;

		if (sys_keyctl(KEYCTL_CLEAR, pop->ring_ids[i], 0) < 0) {
			perror("keyctl(KEYCTL_CLEAR)");
			ret = -1;
		}

		if (sys_keyctl(KEYCTL_UNLINK, pop->ring_ids[i],
			       KEY_SPEC_SESSION_KEYRING) < 0) {
			perror("keyctl(KEYCTL_UNLINK)");
			ret = -1;
		} else {
			pop->ring_ids[i] = 0;
		}
	}

	if (pop->trigger_key) {
		if (sys_keyctl(KEYCTL_UNLINK, pop->trigger_key,
			       KEY_SPEC_SESSION_KEYRING) < 0) {
			perror("keyctl(KEYCTL_UNLINK)");
			ret = -1;
		} else {
			pop->trigger_key = 0;
		}
	}

	if (pop->delay_changed) {
		if (gc_delay_write(pop->saved_gc_delay))
			ret = -1;
		else
			pop->delay_changed = false;
	}

	return ret;
}
