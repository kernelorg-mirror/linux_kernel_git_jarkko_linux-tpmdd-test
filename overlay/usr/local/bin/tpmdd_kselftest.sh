#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

/usr/lib/kselftests/run_kselftest.sh -t tpm2:test_smoke.sh
/usr/lib/kselftests/run_kselftest.sh -t tpm2:test_space.sh
/usr/lib/kselftests/run_kselftest.sh -t tpm2:test_async.sh
