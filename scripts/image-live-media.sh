#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

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

board_dir="${BR2_EXTERNAL_TPMDD_PATH}/board/tpmdd"
stub="${TARGET_DIR}/usr/lib/systemd/boot/efi/${TPMDD_EFI_STUB_NAME}"
kernel="${BINARIES_DIR}/${TPMDD_KERNEL_IMAGE}"
initrd="${TARGET_DIR}/usr/lib/modules/${TPMDD_KERNEL_VERSION}/initramfs.img"
osrel="${TARGET_DIR}/usr/lib/os-release"
oci_archive="${BINARIES_DIR}/image.tar"
manifest="${BINARIES_DIR}/image.manifest"
ssh_template="${board_dir}/ssh_config.in"
live_cmdline="ro rd.overlay systemd.gpt_auto=0 net.ifnames=0 nokaslr tpm_tis.interrupts=0"
output_media="tpmdd_${TPMDD_ARCH}.${TPMDD_MEDIA_EXT}"

if [[ "${TPMDD_ARCH}" == amd64 ]]; then
  rootfs_live="${BINARIES_DIR}/rootfs-live.squashfs"
  ssh_dir="${BINARIES_DIR}/live-ssh"
  genimage_cfg="${board_dir}/genimage.cfg"
  media_cmdline="root=live:CDLABEL=TPMDD ${live_cmdline}${TPMDD_CMDLINE_EXTRA} console=tty0"
else
  rootfs_live="${BINARIES_DIR}/rootfs.squashfs"
  ssh_dir="${TARGET_DIR}/var/roothome/.ssh"
  genimage_cfg="${board_dir}/genimage-arm64.cfg"
  rpi_dts="${board_dir}/rpi/tpm-slb9670-overlay.dts"
  media_cmdline="root=live:LABEL=TPMDD ${live_cmdline}${TPMDD_CMDLINE_EXTRA} console=tty0"
fi

work=$(mktemp -d "${BINARIES_DIR}/media.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "${work}/empty" "${work}/out"

if [[ "${TPMDD_ARCH}" == amd64 ]]; then
  efi_part="${work}/input/efi-part"
  mkdir -p "${efi_part}/EFI/BOOT" "${efi_part}/loader"
  "${HOST_DIR}/bin/ukify" build \
    --stub="${stub}" \
    --linux="${kernel}" \
    --initrd="${initrd}" \
    --cmdline="${media_cmdline}" \
    --os-release="@${osrel}" \
    --uname="${TPMDD_KERNEL_VERSION}" \
    --output="${efi_part}/EFI/BOOT/${TPMDD_EFI_BOOT_NAME}"
  printf 'timeout 0\n' > "${efi_part}/loader/loader.conf"
  find "${efi_part}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
  "${HOST_DIR}/bin/genimage" \
    --rootpath "${work}/empty" \
    --tmppath "${work}/genimage-tmp" \
    --inputpath "${work}/input" \
    --outputpath "${work}/out" \
    --config "${genimage_cfg}"
  mkdir -p "${work}/iso-root/LiveOS" "${work}/iso-root/payload"
  ln -s "${rootfs_live}" "${work}/iso-root/LiveOS/squashfs.img"
  ln -s "${oci_archive}" "${work}/iso-root/payload/image.tar"
  ln -s "${manifest}" "${work}/iso-root/payload/image.manifest"
  iso_date=$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M%S00)
  "${HOST_DIR}/bin/xorriso" -as mkisofs \
    -follow-links \
    -iso-level 3 \
    -R \
    -J \
    -joliet-long \
    -V TPMDD \
    --modification-date="${iso_date}" \
    --set_all_file_dates "${iso_date}" \
    -o "${work}/out/${output_media}" \
    -partition_offset 16 \
    -append_partition 2 0xef "${work}/out/efi-part.vfat" \
    -appended_part_as_gpt \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    "${work}/iso-root"
else
  stage="${work}/stage"
  mkdir -p "${stage}/overlays" "${stage}/LiveOS" "${stage}/EFI/BOOT" "${work}/input"
  cp -a "${BINARIES_DIR}/rpi-firmware/." "${stage}/"
  install -m 0644 "${BINARIES_DIR}/RPI3_EFI.fd" "${stage}/RPI3_EFI.fd"
  install -m 0644 "${BINARIES_DIR}/RPI4_EFI.fd" "${stage}/RPI4_EFI.fd"
  cat > "${stage}/config.txt" <<'CFG'
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
CFG
  "${HOST_DIR}/bin/dtc" -@ -I dts -O dtb -o "${stage}/overlays/tpm-slb9670.dtbo" "${rpi_dts}"
  "${HOST_DIR}/bin/ukify" build \
    --stub="${stub}" \
    --linux="${kernel}" \
    --initrd="${initrd}" \
    --cmdline="${media_cmdline}" \
    --os-release="@${osrel}" \
    --uname="${TPMDD_KERNEL_VERSION}" \
    --output="${stage}/EFI/BOOT/${TPMDD_EFI_BOOT_NAME}"
  ln -s "${rootfs_live}" "${stage}/LiveOS/squashfs.img"
  boot_vfat="${work}/input/tpmdd_arm64.vfat"
  truncate -s 2G "${boot_vfat}"
  "${HOST_DIR}/sbin/mkfs.vfat" -F 32 -n TPMDD "${boot_vfat}"
  (
    cd "${stage}"
    "${HOST_DIR}/bin/mcopy" -i "${boot_vfat}" -s ./* ::
  )
  "${HOST_DIR}/bin/genimage" \
    --rootpath "${work}/empty" \
    --tmppath "${work}/genimage-tmp" \
    --inputpath "${work}/input" \
    --outputpath "${work}/out" \
    --config "${genimage_cfg}"
fi

test -s "${work}/out/${output_media}"
sed -e "s|@IDENTITY_FILE@|${ssh_dir}/id-rsa|g" \
  < "${ssh_template}" \
  > "${work}/out/ssh_config"

for name in "${output_media}" ssh_config; do
  mv -fT "${work}/out/${name}" "${BINARIES_DIR}/${name}"
done
