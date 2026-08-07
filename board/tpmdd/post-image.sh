#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
TPMDD_ARCH=${2:?architecture argument required (amd64 or arm64)}

BOARD_DIR="$(dirname "$0")"
PATH="${HOST_DIR}/bin:${HOST_DIR}/sbin:${PATH}"

kver=$(basename "$(find "${TARGET_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
  | sort | tail -n1)")
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
output_iso="${BINARIES_DIR}/tpmdd_${TPMDD_ARCH}.iso"
efi_part="${BINARIES_DIR}/efi-part"

test -f "${stub}"
test -f "${kernel}"
test -f "${initrd}"
test -f "${rootfs_squashfs}"

printf -v os_release '%s\n' \
  'NAME=tpmdd' \
  'ID=tpmdd' \
  'PRETTY_NAME="linux-tpmdd live test image"'

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

# Generic UEFI live ISO.
# arm64: systemd-boot + dual UKIs (generic QEMU/ACPI vs RPi pftf/DT).
# amd64: single removable UKI as today.
#
# Buildroot's systemd package stages boot*.efi under efi-part/; capture it
# before wiping. UKIs live under EFI/tpmdd/ (not EFI/Linux/) so Type #1
# loader entries alone own the menu — no Type #2 auto-discovery duplicates.
rm -rf "${efi_part}.new"
mkdir -p "${efi_part}.new/EFI/BOOT" "${efi_part}.new/loader"
live_cmdline="ro rd.overlay systemd.gpt_auto=0 net.ifnames=0 nokaslr tpm_tis.interrupts=0"
iso_cmdline="root=live:CDLABEL=TPMDD ${live_cmdline}${cmdline_extra} console=tty0"

if [ "${TPMDD_ARCH}" = arm64 ]; then
  sd_boot="${TARGET_DIR}/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
  [ -f "${sd_boot}" ] || sd_boot="${efi_part}/EFI/BOOT/bootaa64.efi"
  test -f "${sd_boot}"
  install -m 0644 "${sd_boot}" "${efi_part}.new/EFI/BOOT/${efi_boot_name}"

  mkdir -p "${efi_part}.new/EFI/tpmdd"
  build_uki "${efi_part}.new/EFI/tpmdd/tpmdd.efi" "${iso_cmdline}"
  build_uki "${efi_part}.new/EFI/tpmdd/tpmdd-rpi.efi" \
    "${iso_cmdline} acpi=off"

  cat >"${efi_part}.new/loader/loader.conf" <<'EOF'
timeout 5
default tpmdd
EOF

  mkdir -p "${efi_part}.new/loader/entries"
  cat >"${efi_part}.new/loader/entries/tpmdd.conf" <<'EOF'
title tpmdd (UEFI)
efi /EFI/tpmdd/tpmdd.efi
EOF
  cat >"${efi_part}.new/loader/entries/tpmdd-rpi.conf" <<'EOF'
title tpmdd (Raspberry Pi)
efi /EFI/tpmdd/tpmdd-rpi.efi
EOF
else
  build_uki "${efi_part}.new/EFI/BOOT/${efi_boot_name}" "${iso_cmdline}"
  # genimage always packs loader/; keep a minimal conf for the ESP layout.
  cat >"${efi_part}.new/loader/loader.conf" <<'EOF'
timeout 0
EOF
fi

rm -rf "${efi_part}"
mv "${efi_part}.new" "${efi_part}"

support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"

iso_root=$(mktemp -d "${BINARIES_DIR}/iso.XXXXXX")
cleanup() {
  rm -rf "${iso_root}"
}
trap cleanup EXIT
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

cleanup
trap - EXIT

# Raspberry Pi SD images: MBR + single FAT32 (type 0x0c) with pftf UEFI firmware,
# BOOTAA64.EFI UKI, and LiveOS/squashfs.img. RPi CPU boot ROM does not support GPT/ESP.
build_rpi_sd() {
  local variant=$1 fw_src=$2
  local stage boot_vfat cfg img sd_cmdline

  if [ ! -d "${fw_src}" ]; then
    echo "missing RPi UEFI firmware: ${fw_src}" >&2
    return 1
  fi

  stage=$(mktemp -d "${BINARIES_DIR}/rpi-sd-${variant}.XXXXXX")
  boot_vfat="${BINARIES_DIR}/rpi-boot-${variant}.vfat"
  cfg="${BINARIES_DIR}/genimage-sd-${variant}.cfg"
  img="tpmdd_${TPMDD_ARCH}-${variant}.img"
  sd_cmdline="root=live:LABEL=TPMDD ${live_cmdline} acpi=off${cmdline_extra} console=tty0"

  # pftf layout at FAT root (RPI_EFI.fd, start*.elf, config.txt, DTBs, …).
  cp -a "${fw_src}/." "${stage}/"
  rm -f "${stage}/Readme.md"

  # LetsTrust / SLB9670 on SPI0 CE1 (VideoCore applies overlays before pftf UEFI).
  mkdir -p "${stage}/overlays"
  dtc -@ -I dts -O dtb -o "${stage}/overlays/tpm-slb9670.dtbo" \
    "${BOARD_DIR}/rpi/tpm-slb9670-overlay.dts"
  {
    echo 'dtparam=spi=on'
    echo 'dtoverlay=tpm-slb9670'
  } >>"${stage}/config.txt"

  build_uki "${stage}/EFI/BOOT/${efi_boot_name}" "${sd_cmdline}"

  mkdir -p "${stage}/LiveOS"
  ln "${rootfs_squashfs}" "${stage}/LiveOS/squashfs.img"

  # Populate FAT at the volume root; genimage file{} nesting would put files under a subdir.
  rm -f "${boot_vfat}"
  truncate -s 2G "${boot_vfat}"
  mkfs.vfat -F 32 -n TPMDD "${boot_vfat}"
  # Copy stage contents to the FAT root (not a nested directory).
  (
    cd "${stage}"
    mcopy -i "${boot_vfat}" -s ./* ::
  )

  cat >"${cfg}" <<EOF
# SPDX-License-Identifier: GPL-2.0-or-later
# Generated for ${variant}; do not edit.

image ${img} {
	hdimage {
	}

	partition boot {
		partition-type = 0xC
		bootable = "true"
		image = "rpi-boot-${variant}.vfat"
	}
}
EOF

  support/scripts/genimage.sh -c "${cfg}"

  rm -rf "${stage}" "${boot_vfat}" "${cfg}"
}

if [ "${TPMDD_ARCH}" = arm64 ] && [ -d "${BINARIES_DIR}/rpi-uefi/rpi3" ]; then
  build_rpi_sd rpi3b "${BINARIES_DIR}/rpi-uefi/rpi3"
  build_rpi_sd rpi400 "${BINARIES_DIR}/rpi-uefi/rpi4"
fi

SSH_DIR="${TARGET_DIR}/root/.ssh"
sed -e "s|@IDENTITY_FILE@|${SSH_DIR}/id-rsa|g" \
  <"${BOARD_DIR}/ssh_config.in" \
  >"${BINARIES_DIR}/ssh_config"

install -T -m 0755 "${BOARD_DIR}/${TPMDD_ARCH}/run-qemu.sh" \
  "${BINARIES_DIR}/run-qemu.sh"
