#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

set -euo pipefail

if (($# != 3)); then
  echo "usage: $0 <image_path> <device> <board>" >&2
  exit 1
fi

image_path=$1
device=$2
board=$3

if [ -z "$device" ]; then
  echo "error: DEVICE is required, e.g.: make burn BOARD=$board DEVICE=/dev/sdX" >&2
  exit 1
fi
if [ ! -b "$device" ]; then
  echo "error: $device is not a block device" >&2
  exit 1
fi
if [ ! -f "$image_path" ]; then
  echo "error: $image_path not found; run: make build BOARD=$board" >&2
  exit 2
fi

sudo dd if="$image_path" of="$device" bs=1M status=progress oflag=sync
