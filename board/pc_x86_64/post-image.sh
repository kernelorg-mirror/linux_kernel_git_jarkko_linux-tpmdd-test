#!/usr/bin/env bash

set -e

UUID=$(dumpe2fs "$BINARIES_DIR/rootfs.ext2" 2>/dev/null | \
       sed -n 's/^Filesystem UUID: *\(.*\)/\1/p')

echo "UUID: $UUID"

BOARD_DIR="$(dirname "$0")"

# grub2
mkdir -p "${BINARIES_DIR}/efi-part/EFI/BOOT"
sed "s/UUID_TMP/$UUID/g" "${BOARD_DIR}/grub.cfg" > \
    "${BINARIES_DIR}/efi-part/EFI/BOOT/grub.cfg"

# genimage
sed "s/UUID_TMP/$UUID/g" "${BOARD_DIR}/genimage.cfg" > "${BINARIES_DIR}/genimage.cfg"
support/scripts/genimage.sh -c "$BINARIES_DIR/genimage.cfg"

SSH_DIR="${TARGET_DIR}/root/.ssh"

sed -e "s|@IDENTITY_FILE@|$SSH_DIR/id-rsa|g" \
<"${BOARD_DIR}/ssh_config.in" \
>"${BINARIES_DIR}/ssh_config"

function install_script {
  sed \
    -e "s|@HOST_DIR@|${HOST_DIR}|g" \
    <"${BOARD_DIR}/$1.in" \
    >"${BINARIES_DIR}/$1"
  chmod +x "${BINARIES_DIR}/$1"
}
install_script run-qemu.sh
install_script run-tests.sh
install_script test_tpm2_kselftest.exp
install_script test_tpm2_trusted.exp
