#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${BR2_EXTERNAL_TPMDD_PATH:?BR2_EXTERNAL_TPMDD_PATH must be set by Buildroot}"
TPMDD_ARCH=${2:?architecture argument required (amd64 or arm64)}

SSH_DIR="${TARGET_DIR}/root/.ssh"
install -d -m 0700 "${SSH_DIR}"

if [ ! -f "${SSH_DIR}/id-rsa" ]; then
  ssh-keygen -C 'root@tpmdd' -t rsa -f "${SSH_DIR}/id-rsa" -N ''
  cp -f "${SSH_DIR}"/{id-rsa.pub,authorized_keys}
  chmod 600 "${SSH_DIR}/authorized_keys"
fi

kver=$(basename "$(find "${TARGET_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
  | sort | tail -n1)")
test -n "${kver}"

case "${TPMDD_ARCH}" in
  amd64)
    kernel="${TARGET_DIR}/boot/bzImage"
    dracut_arch=x86_64
    ;;
  arm64)
    kernel="${TARGET_DIR}/boot/Image"
    dracut_arch=aarch64
    ;;
  *)
    echo "unknown TPMDD_ARCH: ${TPMDD_ARCH}" >&2
    exit 1
    ;;
esac

install -Dm644 "${kernel}" "${TARGET_DIR}/usr/lib/modules/${kver}/vmlinuz"
install -Dm755 "${BR2_EXTERNAL_TPMDD_PATH}/board/tpmdd/dracut-util" \
  "${TARGET_DIR}/usr/lib/dracut/dracut-util"
install -Dm644 "${BR2_EXTERNAL_TPMDD_PATH}/board/tpmdd/dracut.conf" \
  "${TARGET_DIR}/etc/dracut.conf.d/30-tpmdd.conf"

# dracut-install prefixes absolute module paths with the sysroot. Expose only
# the host dracut directory there so target binaries still win path lookup.
host_dracut_link="${TARGET_DIR}${HOST_DIR}/lib/dracut"
mkdir -p "$(dirname "${host_dracut_link}")"
ln -sfn "${HOST_DIR}/lib/dracut" "${host_dracut_link}"
cleanup_host_dracut_link() {
  rm -f "${host_dracut_link}"
  rmdir -p "$(dirname "${host_dracut_link}")" 2>/dev/null || true
}
trap cleanup_host_dracut_link EXIT

# Use the target shell implementation instead of installing host dracut-util.
# shellcheck disable=SC2016
sed -i \
  's|inst_binary "${dracutbasedir}/dracut-util" "/usr/bin/dracut-util"|inst_script "/usr/lib/dracut/dracut-util" "/usr/bin/dracut-util"|' \
  "${HOST_DIR}/lib/dracut/modules.d/80base/module-setup.sh"

# Make systemd module probing inspect the initramfs being assembled.
# shellcheck disable=SC2016
sed -i \
  's|\[\[ -f "$systemdsystemunitdir"/$i \]\]|[[ -f "$initdir/$systemdsystemunitdir"/$i ]]|g' \
  "${HOST_DIR}/lib/dracut/modules.d/10systemd/module-setup.sh"

pre_mount_service="${HOST_DIR}/lib/dracut/modules.d/77dracut-systemd/dracut-pre-mount.service"
if ! grep -q '^After=.*dracut-cmdline.service' "${pre_mount_service}"; then
  sed -i 's|^After=|After=dracut-cmdline.service |' "${pre_mount_service}"
fi
if ! grep -q '^Wants=dracut-cmdline.service$' "${pre_mount_service}"; then
  sed -i \
    's|^\(ConditionPathExists=/usr/lib/initrd-release\)$|Wants=dracut-cmdline.service\n\1|' \
    "${pre_mount_service}"
fi

# shellcheck disable=SC2016
sed -i \
  's|$SYSTEMCTL -q --root "$initdir" enable dracut-initqueue.service|$SYSTEMCTL -q --root "$initdir" add-wants initrd.target dracut-initqueue.service|' \
  "${HOST_DIR}/lib/dracut/modules.d/77initqueue/module-setup.sh"

# OverlayFS is built into the live kernels, but dracut has no drivers_dir when
# assembling against a sysroot.
sed -i \
  's#require_kernel_modules overlay || return 1#return 255#' \
  "${HOST_DIR}/lib/dracut/modules.d/70overlayfs/module-setup.sh"

DRACUT_ARCH="${dracut_arch}" "${HOST_DIR}/bin/dracut" \
  --sysroot "${TARGET_DIR}" \
  --tmpdir "${BINARIES_DIR}" \
  --force "${BINARIES_DIR}/initramfs.img" "${kver}"
