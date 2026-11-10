#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${BR2_EXTERNAL_TPMDD_PATH:?BR2_EXTERNAL_TPMDD_PATH must be set by Buildroot}"
export TPMDD_ARCH=${2:?architecture argument required (amd64 or arm64)}
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by Buildroot}"
export SOURCE_DATE_EPOCH TZ=UTC

cd -- "${BR2_EXTERNAL_TPMDD_PATH}"
. scripts/image-lib.sh

bootc_bin="${TARGET_DIR}/usr/bin/bootc"
bootc_ldso="${TARGET_DIR}/lib/${TPMDD_LDSO_NAME}"
bootc_libpath="${TARGET_DIR}/lib:${TARGET_DIR}/usr/lib"
if [[ ! -x "${bootc_bin}" ]]; then
  echo "warning: skipping bootc container lint: ${bootc_bin} missing" >&2
elif [[ "$(uname -m)" == "${TPMDD_TARGET_ARCH}" && -x "${bootc_ldso}" ]]; then
  "${bootc_ldso}" --library-path "${bootc_libpath}" "${bootc_bin}" \
    container lint --rootfs "${TARGET_DIR}" --skip baseimage-root --skip baseimage-composefs
else
  echo "warning: skipping bootc container lint: cannot run target bootc on host" >&2
fi

"${BR2_EXTERNAL_TPMDD_PATH}/scripts/image-manifest.sh"
"${BR2_EXTERNAL_TPMDD_PATH}/scripts/image-live-rootfs.sh"
"${BR2_EXTERNAL_TPMDD_PATH}/scripts/image-live-media.sh"
