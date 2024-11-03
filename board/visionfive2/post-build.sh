#!/usr/bin/env sh

set -e

BOARD_DIR="$(dirname "$0")"
mkdir -p "${TARGET_DIR}/boot/extlinux"
cp -v "${BOARD_DIR}/extlinux.conf" "${TARGET_DIR}/boot/extlinux/extlinux.conf"
