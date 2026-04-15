#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

BOARD_DIR="$(dirname "$0")"

support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"
support/scripts/genimage.sh -c "${BOARD_DIR}/genimage_spi-nor.cfg"
