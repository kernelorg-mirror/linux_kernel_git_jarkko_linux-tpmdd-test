#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

UUID=$(dumpe2fs "$BINARIES_DIR/rootfs.ext2" 2>/dev/null | \
       sed -n 's/^Filesystem UUID: *\(.*\)/\1/p')

echo "UUID: $UUID"

BOARD_DIR="$(dirname "$0")"
source "${BOARD_DIR}/rpi-variant"

# U-Boot
sed -e "s/PARTUUID_TMP/$UUID/g" -e "s/DTB_TMP/$RPI_DTB/g" "${BOARD_DIR}/boot.cmd" > "${BINARIES_DIR}/boot.cmd"
mkimage -C none -A arm64 -T script -d "${BINARIES_DIR}/boot.cmd" "${BINARIES_DIR}/boot.scr"

# genimage
sed -e "s/UUID_TMP/$UUID/g" -e "s/DTB_TMP/$RPI_DTB/g" "${BOARD_DIR}/genimage.cfg" > "${BINARIES_DIR}/genimage.cfg"
support/scripts/genimage.sh -c "$BINARIES_DIR/genimage.cfg"

SSH_DIR="${TARGET_DIR}/root/.ssh"

sed -e "s|@IDENTITY_FILE@|$SSH_DIR/id-rsa|g" \
<"${BOARD_DIR}/ssh_config.in" \
>"${BINARIES_DIR}/ssh_config"

install -T -m 755 "${BOARD_DIR}/run-qemu.sh" "${BINARIES_DIR}/run-qemu.sh"

