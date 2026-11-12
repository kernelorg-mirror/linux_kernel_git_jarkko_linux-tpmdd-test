#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

if [[ "${1:-}" == --pack ]]; then
  shift
  rootfs=$1
  stage=$2
  output=$3
  digest=$4
  installer_config=$5
  live_ssh=$6
  source_date_epoch=$7

  unsquashfs -quiet -d "${stage}" "${rootfs}"
  sed -i 's/^root:[^:]*:/root::/' "${stage}/etc/shadow"
  install -d -m 0700 "${stage}/var/roothome/.ssh"
  install -m 0600 "${live_ssh}/id-rsa" "${stage}/var/roothome/.ssh/id-rsa"
  install -m 0644 "${live_ssh}/id-rsa.pub" "${stage}/var/roothome/.ssh/id-rsa.pub"
  install -m 0600 "${live_ssh}/id-rsa.pub" "${stage}/var/roothome/.ssh/authorized_keys"
  chown -R 0:0 "${stage}/var/roothome/.ssh"
  install -d "${stage}/usr/share/tpmdd"
  sed "s/@OCI_DIGEST@/${digest}/" "${installer_config}" \
    > "${stage}/usr/share/tpmdd/installer.yaml"
  grep -q '^PUU_INSTALL_CONFIG=' "${stage}/etc/environment" 2>/dev/null ||
    printf 'PUU_INSTALL_CONFIG=/usr/share/tpmdd/installer.yaml\n' \
      >> "${stage}/etc/environment"
  pam_config="${stage}/etc/pam.d/system-auth"
  test -f "${pam_config}"
  grep -q pam_env.so "${pam_config}" ||
    printf 'session  required pam_env.so\n' >> "${pam_config}"
  install -d -m 0755 "${stage}/etc/sudoers.d"
  printf 'Defaults env_file=/etc/environment\n' \
    > "${stage}/etc/sudoers.d/30-tpmdd-install"
  chmod 0440 "${stage}/etc/sudoers.d/30-tpmdd-install"
  chown 0:0 "${stage}/etc/sudoers.d/30-tpmdd-install"
  chown -R 0:0 "${stage}/usr/share/tpmdd"
  touch -d "@${source_date_epoch}" \
    "${stage}/usr/share/tpmdd" "${stage}/usr/share/tpmdd/installer.yaml" \
    "${stage}/etc/shadow" \
    "${stage}/etc/environment" "${stage}/etc/pam.d/system-auth" \
    "${stage}/etc/sudoers.d/30-tpmdd-install"
  SOURCE_DATE_EPOCH="${source_date_epoch}" mksquashfs "${stage}" "${output}" -noappend -comp gzip
  exit 0
fi

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${BR2_EXTERNAL_TPMDD_PATH:?BR2_EXTERNAL_TPMDD_PATH must be set by Buildroot}"
: "${TPMDD_ARCH:?TPMDD_ARCH must be set (amd64 or arm64)}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by Buildroot}"
export SOURCE_DATE_EPOCH TZ=UTC
export PATH="${HOST_DIR}/bin:${HOST_DIR}/sbin:${PATH}"

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
. scripts/image-lib.sh

[[ "${TPMDD_ARCH}" == amd64 ]] || exit 0

live_ssh="${BINARIES_DIR}/live-ssh"
install -d -m 0700 "${live_ssh}"
if [[ ! -f "${live_ssh}/id-rsa" ]]; then
  ssh-keygen -C 'root@linux-tpmdd' -t rsa -f "${live_ssh}/id-rsa" -N ''
fi

state_helper="${PWD}/scripts/state.py"
state="${BINARIES_DIR}/.image-live-rootfs.state"
rootfs="${BINARIES_DIR}/rootfs.squashfs"
oci_source="${BINARIES_DIR}/image.tar"
output="${BINARIES_DIR}/rootfs-live.squashfs"
installer_config="${BR2_EXTERNAL_TPMDD_PATH}/board/tpmdd/installer.yaml"
oci_digest=$(python3 "${state_helper}" oci-digest "${oci_source}")

inputs=(
  --value "arch=${TPMDD_ARCH}"
  --value "epoch=${SOURCE_DATE_EPOCH}"
  --value "oci_digest=${oci_digest}"
)
for path in \
  "${PWD}/scripts/image-live-rootfs.sh" \
  "${PWD}/scripts/image-lib.sh" \
  "${state_helper}" \
  "${rootfs}" \
  "${installer_config}" \
  "${live_ssh}/id-rsa" \
  "${live_ssh}/id-rsa.pub" \
  "${HOST_DIR}/bin/fakeroot" \
  "${HOST_DIR}/bin/faked" \
  "${HOST_DIR}/bin/unsquashfs" \
  "${HOST_DIR}/bin/mksquashfs"; do
  resolved=$(realpath -e "${path}")
  inputs+=(--path "${path}")
  [[ "${path}" == "${resolved}" ]] || inputs+=(--path "${resolved}")
done

key=$(python3 "${state_helper}" key "${inputs[@]}")
if python3 "${state_helper}" check "${state}" --key "${key}" --metadata-path "${output}"; then
  echo "live rootfs is up to date"
  exit 0
else
  status=$?
  [[ "${status}" == 1 ]] || exit "${status}"
fi

work=$(mktemp -d "${BINARIES_DIR}/rootfs-live.XXXXXX")
published=0
committed=0
trap '
  if [[ "${published}" == 1 && "${committed}" == 0 ]]; then
    if [[ -e "${work}/previous" || -L "${work}/previous" ]]; then
      mv -fT "${work}/previous" "${output}"
    else
      rm -f "${output}"
    fi
  fi
  rm -rf -- "${work}"
' EXIT
trap 'exit 1' HUP INT TERM

"${HOST_DIR}/bin/fakeroot" -- "${PWD}/scripts/image-live-rootfs.sh" --pack \
  "${rootfs}" "${work}/root" "${work}/rootfs.squashfs" "${oci_digest}" \
  "${installer_config}" "${live_ssh}" "${SOURCE_DATE_EPOCH}"

test -s "${work}/rootfs.squashfs"
if [[ -e "${output}" || -L "${output}" ]]; then
  ln -P "${output}" "${work}/previous"
fi
published=1
mv -fT "${work}/rootfs.squashfs" "${output}"
python3 "${state_helper}" save "${state}" --key "${key}" --metadata-path "${output}"
committed=1
