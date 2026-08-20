#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${BR2_EXTERNAL_TPMDD_PATH:?BR2_EXTERNAL_TPMDD_PATH must be set by Buildroot}"
TPMDD_ARCH=${2:?architecture argument required (amd64 or arm64)}

kver=$(basename "$(find "${TARGET_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
  | sort -V | tail -n1)")
test -n "${kver}"

case "${TPMDD_ARCH}" in
  amd64)
    kernel="${TARGET_DIR}/boot/bzImage"
    ;;
  arm64)
    kernel="${TARGET_DIR}/boot/Image"
    ;;
  *)
    echo "unknown TPMDD_ARCH: ${TPMDD_ARCH}" >&2
    exit 1
    ;;
esac

install -Dm644 "${kernel}" "${TARGET_DIR}/usr/lib/modules/${kver}/vmlinuz"

# bootc container identity
tpmdd_version="${TPMDD_VERSION:-0}"
install -d -m 0755 "${TARGET_DIR}/usr/lib" "${TARGET_DIR}/etc"
cat > "${TARGET_DIR}/usr/lib/os-release" <<OSREL
NAME=tpmdd
ID=tpmdd
VERSION="${tpmdd_version}"
VERSION_ID=${tpmdd_version}
PRETTY_NAME="linux-tpmdd ${tpmdd_version}"
IMAGE_ID=tpmdd
IMAGE_VERSION=${tpmdd_version}
OSREL
ln -sfn ../usr/lib/os-release "${TARGET_DIR}/etc/os-release"

install -Dm755 "${BR2_EXTERNAL_TPMDD_PATH}/board/tpmdd/dracut-util" \
  "${TARGET_DIR}/usr/lib/dracut/dracut-util"
install -Dm644 "${BR2_EXTERNAL_TPMDD_PATH}/board/tpmdd/dracut.conf" \
  "${TARGET_DIR}/etc/dracut.conf.d/30-tpmdd.conf"

# bootc/OSTree rootfs layout: mutable paths live under /var.
for d in boot home root usr/local srv opt mnt var; do
  rm -rf "${TARGET_DIR:?}/${d}"
done

mkdir -p \
  "${TARGET_DIR}/sysroot" \
  "${TARGET_DIR}/efi" \
  "${TARGET_DIR}/boot" \
  "${TARGET_DIR}/usr/lib/ostree" \
  "${TARGET_DIR}/var" \
  "${TARGET_DIR}/var/tmp" \
  "${TARGET_DIR}/var/roothome" \
  "${TARGET_DIR}/var/home" \
  "${TARGET_DIR}/var/srv" \
  "${TARGET_DIR}/var/opt" \
  "${TARGET_DIR}/var/mnt" \
  "${TARGET_DIR}/var/usrlocal" \
  "${TARGET_DIR}/usr/lib/tmpfiles.d"

cat > "${TARGET_DIR}/usr/lib/ostree/prepare-root.conf" <<'PREPARE'
[composefs]
enabled = true
[sysroot]
readonly = true
PREPARE

{
  for dir in opt home srv mnt usrlocal; do
    echo "d /var/${dir} 0755 root root -"
  done
  echo "d /var/roothome 0700 root root -"
  echo "d /run/media 0755 root root -"
} > "${TARGET_DIR}/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

# Drop systemd tmpfiles that assume /home, /srv, /root are real directories.
if [ -f "${TARGET_DIR}/usr/lib/tmpfiles.d/home.conf" ]; then
  sed -i -E '/^[Qq][[:space:]]+\/(home|srv)\b/d' \
    "${TARGET_DIR}/usr/lib/tmpfiles.d/home.conf"
fi
if [ -f "${TARGET_DIR}/usr/lib/tmpfiles.d/provision.conf" ]; then
  sed -i -E '/^d-?[[:space:]]+\/root[[:space:]]+:?0[0-9]{3}/d' \
    "${TARGET_DIR}/usr/lib/tmpfiles.d/provision.conf"
fi

# dracut-install prefixes absolute module paths with the sysroot. Bridge only
# host lib/dracut so target binaries still win path lookup.
host_dracut_link="${TARGET_DIR}${HOST_DIR}/lib/dracut"
mkdir -p "$(dirname "${host_dracut_link}")"
ln -sfn "${HOST_DIR}/lib/dracut" "${host_dracut_link}"
cleanup_host_dracut_link() {
  rm -f "${host_dracut_link}"
  rmdir -p "$(dirname "${host_dracut_link}")" 2>/dev/null || true
}
trap cleanup_host_dracut_link EXIT

"${HOST_DIR}/bin/dracut" --sysroot "${TARGET_DIR}" \
  --tmpdir "${BINARIES_DIR}" \
  --force "${TARGET_DIR}/usr/lib/modules/${kver}/initramfs.img" "${kver}"

cleanup_host_dracut_link
trap - EXIT

ln -sfT sysroot/ostree "${TARGET_DIR}/ostree"
ln -sfT var/roothome "${TARGET_DIR}/root"
ln -sfT var/srv "${TARGET_DIR}/srv"
ln -sfT var/opt "${TARGET_DIR}/opt"
ln -sfT var/mnt "${TARGET_DIR}/mnt"
ln -sfT var/home "${TARGET_DIR}/home"
ln -sfT ../var/usrlocal "${TARGET_DIR}/usr/local"

find "${TARGET_DIR}/etc/systemd/system" -type l -regextype posix-extended \
  -regex '.*/Cu[[:alnum:]]{6}' -delete

# SSH key for the live image (lives under /var after the bootc reshape).
SSH_DIR="${TARGET_DIR}/var/roothome/.ssh"
install -d -m 0700 "${SSH_DIR}"
if [ ! -f "${SSH_DIR}/id-rsa" ]; then
  ssh-keygen -C 'root@tpmdd' -t rsa -f "${SSH_DIR}/id-rsa" -N ''
  cp -f "${SSH_DIR}"/{id-rsa.pub,authorized_keys}
  chmod 600 "${SSH_DIR}/authorized_keys"
fi
