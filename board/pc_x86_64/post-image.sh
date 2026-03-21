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
    -e "s|@BINARIES_DIR@|${BINARIES_DIR}|g" \
    -e "s|@HOST_DIR@|${HOST_DIR}|g" \
    <"${BOARD_DIR}/$1.in" \
    >"${BINARIES_DIR}/$1"
  chmod +x "${BINARIES_DIR}/$1"
}

install_script run-qemu.sh
install_script run-tests.sh
install_script test_tpm2_kselftest.exp
install_script test_tpm2_trusted.exp
install_script test_rootns.exp

OVMF_CODE_OUT="$BINARIES_DIR/OVMF_CODE.fd"
OVMF_VARS_OUT="$BINARIES_DIR/OVMF_VARS.fd"
OVMF_CANDIDATES="
/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd
/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/qemu/OVMF_CODE.fd:/usr/share/qemu/OVMF_VARS.fd
/usr/share/qemu/OVMF_CODE.secboot.fd:/usr/share/qemu/OVMF_VARS.secboot.fd
/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd
/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd
/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd
"

OVMF_CODE_IN=
OVMF_VARS_IN=
for pair in $OVMF_CANDIDATES; do
  OVMF_CODE_IN=${pair%%:*}
  OVMF_VARS_IN=${pair#*:}
  if [ -f "$OVMF_CODE_IN" ] && [ -f "$OVMF_VARS_IN" ]; then
    break
  fi
done

if [ -z "$OVMF_CODE_IN" ] || [ -z "$OVMF_VARS_IN" ]; then
  echo "OVMF firmware not found" >&2
  exit 1
fi

cp "$OVMF_CODE_IN" "$OVMF_CODE_OUT"
cp "$OVMF_VARS_IN" "$OVMF_VARS_OUT"
