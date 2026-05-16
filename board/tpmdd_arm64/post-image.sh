#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

UUID=$(dumpe2fs "$BINARIES_DIR/rootfs.ext2" 2>/dev/null | \
       sed -n 's/^Filesystem UUID: *\(.*\)/\1/p')

echo "UUID: $UUID"

BOARD_DIR="$(dirname "$0")"

# systemd-boot
mkdir -p "${BINARIES_DIR}/efi-part/loader/entries"
cp "${BOARD_DIR}/loader.conf" "${BINARIES_DIR}/efi-part/loader/loader.conf"
sed "s/PARTUUID_TMP/$UUID/g" "${BOARD_DIR}/tpmdd.conf.in" > \
    "${BINARIES_DIR}/efi-part/loader/entries/tpmdd.conf"
rm -f "${BINARIES_DIR}/efi-part/loader/entries/buildroot.conf"

# genimage
sed "s/UUID_TMP/$UUID/g" "${BOARD_DIR}/genimage.cfg" > "${BINARIES_DIR}/genimage.cfg"
support/scripts/genimage.sh -c "$BINARIES_DIR/genimage.cfg"

SSH_DIR="${TARGET_DIR}/root/.ssh"

sed -e "s|@IDENTITY_FILE@|$SSH_DIR/id-rsa|g" \
<"${BOARD_DIR}/ssh_config.in" \
>"${BINARIES_DIR}/ssh_config"

install -T -m 755 "${BOARD_DIR}/run-qemu.sh" "${BINARIES_DIR}/run-qemu.sh"

# Create 64MB pflash images for QEMU from host AAVMF firmware
AAVMF_CODE_OUT="$BINARIES_DIR/AAVMF_CODE.fd"
AAVMF_VARS_OUT="$BINARIES_DIR/AAVMF_VARS.fd"
AAVMF_CANDIDATES="
/usr/share/AAVMF/AAVMF_CODE.fd:/usr/share/AAVMF/AAVMF_VARS.fd
/usr/share/AAVMF/AAVMF_CODE.ms.fd:/usr/share/AAVMF/AAVMF_VARS.ms.fd
/usr/share/qemu-efi-aarch64/QEMU_EFI.fd:/usr/share/AAVMF/AAVMF_VARS.fd
/usr/share/edk2/aarch64/QEMU_EFI.fd:/usr/share/edk2/aarch64/vars-template-pflash.raw
/usr/share/edk2-armvirt/aarch64/QEMU_CODE.fd:/usr/share/edk2-armvirt/aarch64/QEMU_VARS.fd
"

AAVMF_CODE_IN=
AAVMF_VARS_IN=
for pair in $AAVMF_CANDIDATES; do
  AAVMF_CODE_IN=${pair%%:*}
  AAVMF_VARS_IN=${pair#*:}
  if [ -f "$AAVMF_CODE_IN" ] && [ -f "$AAVMF_VARS_IN" ]; then
    break
  fi
  AAVMF_CODE_IN=
  AAVMF_VARS_IN=
done

if [ -n "$AAVMF_CODE_IN" ] && [ -n "$AAVMF_VARS_IN" ]; then
  # Pad to 64MB for QEMU aarch64 pflash
  dd if=/dev/zero of="$AAVMF_CODE_OUT" bs=1M count=64 2>/dev/null
  dd if="$AAVMF_CODE_IN" of="$AAVMF_CODE_OUT" conv=notrunc 2>/dev/null
  dd if=/dev/zero of="$AAVMF_VARS_OUT" bs=1M count=64 2>/dev/null
  dd if="$AAVMF_VARS_IN" of="$AAVMF_VARS_OUT" conv=notrunc 2>/dev/null
else
  echo "WARNING: AAVMF firmware not found, QEMU boot will not work" >&2
  echo "Install qemu-efi-aarch64 or edk2-aarch64 package on host" >&2
fi
