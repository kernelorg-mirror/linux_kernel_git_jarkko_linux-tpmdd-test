#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

readonly uri=qemu:///session

usage() {
  echo "usage: $0 IMAGE ARCH" >&2
  echo "  IMAGE  board disk image (.iso or .img)" >&2
  echo "  ARCH   x86_64 or aarch64" >&2
  exit 2
}

readonly image=${1:-}
readonly arch=${2:-}
if [[ -z "${image}" || -z "${arch}" ]]; then
  usage
fi
if [[ ! -f "${image}" ]]; then
  echo "error: image not found: ${image}" >&2
  exit 2
fi

case "${arch}" in
  x86_64)
    machine=q35
    cpu_args=()
    ;;
  aarch64)
    machine=virt
    cpu_args=(--cpu cortex-a72)
    ;;
  *)
    echo "error: unsupported ARCH=${arch} (expected x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

if ! command -v virt-install >/dev/null 2>&1 || ! command -v virsh >/dev/null 2>&1; then
  echo "error: virt-install and virsh are required" >&2
  exit 1
fi

digest=$(sha256sum -- "${image}" | cut -c1-4)
readonly name=tpmdd-${digest}

if virsh --connect "${uri}" dominfo "${name}" >/dev/null 2>&1; then
  echo "domain ${name} already defined on ${uri}"
  exit 0
fi

virt-install \
  --connect "${uri}" \
  --name "${name}" \
  --memory 2048 \
  --vcpus 2 \
  --arch "${arch}" \
  --machine "${machine}" \
  "${cpu_args[@]}" \
  --import \
  --disk "path=${image},format=raw,bus=virtio" \
  --boot uefi \
  --os-variant generic \
  --network user,model=virtio \
  --graphics none \
  --console pty \
  --tpm emulator \
  --noautoconsole \
  --noreboot

echo "defined ${name} on ${uri}"
