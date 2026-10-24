#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
trap 'exit 1' HUP INT TERM
cp -a /usr/lib/kselftests/. "$workdir/"

"$workdir/run_kselftest.sh" -t tpm2:test_smoke.sh
"$workdir/run_kselftest.sh" -t tpm2:test_space.sh
"$workdir/run_kselftest.sh" -t tpm2:test_async.sh
