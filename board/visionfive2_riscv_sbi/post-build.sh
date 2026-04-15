#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

BOARD_DIR="$(dirname "$0")"
mkdir -p "${TARGET_DIR}/boot/extlinux"
cp -v "${BOARD_DIR}/extlinux.conf" "${TARGET_DIR}/boot/extlinux/extlinux.conf"
