#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
TPMDD_ARCH=${2:?architecture argument required (amd64 or arm64)}
TPMDD_VERSION=${TPMDD_VERSION:-0}

BOARD_DIR="$(dirname "$0")"
PATH="${HOST_DIR}/bin:${HOST_DIR}/sbin:${PATH}"

kver=$(basename "$(find "${TARGET_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
  | sort -V | tail -n1)")
test -n "${kver}"

case "${TPMDD_ARCH}" in
  amd64)
    stub="${TARGET_DIR}/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
    kernel="${BINARIES_DIR}/bzImage"
    efi_boot_name="BOOTX64.EFI"
    cmdline_extra=" console=ttyS0,115200n8"
    ;;
  arm64)
    stub="${TARGET_DIR}/usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
    kernel="${BINARIES_DIR}/Image"
    efi_boot_name="BOOTAA64.EFI"
    cmdline_extra=" console=ttyAMA0,115200n8"
    ;;
  *)
    echo "unknown TPMDD_ARCH: ${TPMDD_ARCH}" >&2
    exit 1
    ;;
esac

initrd="${BINARIES_DIR}/initramfs.img"
rootfs_squashfs="${BINARIES_DIR}/rootfs.squashfs"

test -f "${stub}"
test -f "${kernel}"
test -f "${initrd}"
test -f "${rootfs_squashfs}"

printf -v os_release '%s\n' \
  'NAME=tpmdd' \
  'ID=tpmdd' \
  "VERSION=\"${TPMDD_VERSION}\"" \
  "VERSION_ID=${TPMDD_VERSION}" \
  "PRETTY_NAME=\"linux-tpmdd ${TPMDD_VERSION} live test image\""

build_uki() {
  local out=$1 cmdline=$2

  mkdir -p "$(dirname "${out}")"
  ukify build \
    --stub="${stub}" \
    --linux="${kernel}" \
    --initrd="${initrd}" \
    --cmdline="${cmdline}" \
    --os-release="${os_release}" \
    --uname="${kver}" \
    --output="${out}"
}

live_cmdline="ro rd.overlay systemd.gpt_auto=0 net.ifnames=0 nokaslr tpm_tis.interrupts=0"

build_amd64_iso() {
  local efi_part iso_cmdline output_iso

  efi_part="${BINARIES_DIR}/efi-part"
  iso_cmdline="root=live:CDLABEL=TPMDD ${live_cmdline}${cmdline_extra} console=tty0"
  output_iso="${BINARIES_DIR}/tpmdd_${TPMDD_ARCH}.iso"

  rm -rf "${efi_part}.new"
  mkdir -p "${efi_part}.new/EFI/BOOT" "${efi_part}.new/loader"
  build_uki "${efi_part}.new/EFI/BOOT/${efi_boot_name}" "${iso_cmdline}"
  cat >"${efi_part}.new/loader/loader.conf" <<'EOF'
timeout 0
EOF
  rm -rf "${efi_part}"
  mv "${efi_part}.new" "${efi_part}"

  support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"

  iso_root=$(mktemp -d "${BINARIES_DIR}/iso.XXXXXX")
  trap 'rm -rf "${iso_root}"' EXIT
  mkdir -p "${iso_root}/LiveOS"
  ln "${rootfs_squashfs}" "${iso_root}/LiveOS/squashfs.img"

  xorriso -as mkisofs \
    -iso-level 3 \
    -R \
    -J \
    -joliet-long \
    -V TPMDD \
    -o "${output_iso}" \
    -partition_offset 16 \
    -append_partition 2 0xef "${BINARIES_DIR}/efi-part.vfat" \
    -appended_part_as_gpt \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    "${iso_root}"

  rm -rf "${iso_root}"
  trap - EXIT
}

build_arm64_image() {
  local sd_cmdline

  test -d "${BINARIES_DIR}/rpi-firmware"
  test -f "${BINARIES_DIR}/RPI3_EFI.fd"
  test -f "${BINARIES_DIR}/RPI4_EFI.fd"

  stage=$(mktemp -d "${BINARIES_DIR}/arm64.XXXXXX")
  boot_vfat="${BINARIES_DIR}/tpmdd_arm64.vfat"
  trap 'rm -rf "${stage}" "${boot_vfat}"' EXIT

  cp -a "${BINARIES_DIR}/rpi-firmware/." "${stage}/"
  install -m 0644 "${BINARIES_DIR}/RPI3_EFI.fd" "${stage}/RPI3_EFI.fd"
  install -m 0644 "${BINARIES_DIR}/RPI4_EFI.fd" "${stage}/RPI4_EFI.fd"

  cat >"${stage}/config.txt" <<'EOF'
arm_64bit=1
disable_overscan=1
enable_uart=1
uart_2ndstage=1

[pi3]
armstub=RPI3_EFI.fd
disable_commandline_tags=2
device_tree_address=0x1f0000
device_tree_end=0x200000

[pi4]
arm_boost=1
armstub=RPI4_EFI.fd
disable_commandline_tags=1
enable_gic=1
device_tree_address=0x3e0000
device_tree_end=0x400000
dtoverlay=miniuart-bt
dtoverlay=upstream-pi4

[all]
dtparam=spi=on
dtoverlay=tpm-slb9670
EOF

  mkdir -p "${stage}/overlays" "${stage}/LiveOS"
  dtc -@ -I dts -O dtb -o "${stage}/overlays/tpm-slb9670.dtbo" \
    "${BOARD_DIR}/rpi/tpm-slb9670-overlay.dts"

  sd_cmdline="root=live:LABEL=TPMDD ${live_cmdline}${cmdline_extra} console=tty0"
  build_uki "${stage}/EFI/BOOT/${efi_boot_name}" "${sd_cmdline}"
  ln "${rootfs_squashfs}" "${stage}/LiveOS/squashfs.img"

  rm -f \
    "${BINARIES_DIR}/tpmdd_arm64.img" \
    "${BINARIES_DIR}/tpmdd_arm64.iso" \
    "${BINARIES_DIR}/tpmdd_arm64-rpi3b.img" \
    "${BINARIES_DIR}/tpmdd_arm64-rpi400.img" \
    "${boot_vfat}"
  truncate -s 2G "${boot_vfat}"
  mkfs.vfat -F 32 -n TPMDD "${boot_vfat}"
  (
    cd "${stage}"
    mcopy -i "${boot_vfat}" -s ./* ::
  )

  support/scripts/genimage.sh -c "${BOARD_DIR}/genimage-arm64.cfg"

  rm -rf "${stage}" "${boot_vfat}"
  trap - EXIT
}

case "${TPMDD_ARCH}" in
  amd64) build_amd64_iso ;;
  arm64) build_arm64_image ;;
esac

SSH_DIR="${TARGET_DIR}/root/.ssh"
sed -e "s|@IDENTITY_FILE@|${SSH_DIR}/id-rsa|g" \
  <"${BOARD_DIR}/ssh_config.in" \
  >"${BINARIES_DIR}/ssh_config"

install -T -m 0755 "${BOARD_DIR}/qemu-exec.sh" \
  "${BINARIES_DIR}/qemu-exec.sh"
