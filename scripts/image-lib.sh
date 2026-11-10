# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

: "${TPMDD_ARCH:?TPMDD_ARCH must be set (amd64 or arm64)}"

case "${TPMDD_ARCH}" in
  amd64)
    export TPMDD_TARGET_ARCH=x86_64
    export TPMDD_KERNEL_IMAGE=bzImage
    export TPMDD_EFI_BOOT_NAME=BOOTX64.EFI
    export TPMDD_EFI_STUB_NAME=linuxx64.efi.stub
    export TPMDD_LDSO_NAME=ld-linux-x86-64.so.2
    export TPMDD_CMDLINE_EXTRA=" console=ttyS0,115200n8"
    export TPMDD_MEDIA_EXT=iso
    ;;
  arm64)
    export TPMDD_TARGET_ARCH=aarch64
    export TPMDD_KERNEL_IMAGE=Image
    export TPMDD_EFI_BOOT_NAME=BOOTAA64.EFI
    export TPMDD_EFI_STUB_NAME=linuxaa64.efi.stub
    export TPMDD_LDSO_NAME=ld-linux-aarch64.so.1
    export TPMDD_CMDLINE_EXTRA=" console=ttyAMA0,115200n8"
    export TPMDD_MEDIA_EXT=img
    ;;
  *)
    echo "unknown TPMDD_ARCH: ${TPMDD_ARCH}" >&2
    exit 1
    ;;
esac

if [[ -n "${TARGET_DIR:-}" && -d "${TARGET_DIR}/usr/lib/modules" ]]; then
  kver_dir=$(find "${TARGET_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n1)
  test -n "${kver_dir}"
  TPMDD_KERNEL_VERSION=$(basename "${kver_dir}")
  export TPMDD_KERNEL_VERSION
fi
