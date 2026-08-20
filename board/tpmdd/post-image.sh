#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${TARGET_DIR:?TARGET_DIR must be set by Buildroot}"
: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${BUILD_DIR:?BUILD_DIR must be set by Buildroot}"
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
    oci_goarch="amd64"
    ;;
  arm64)
    stub="${TARGET_DIR}/usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
    kernel="${BINARIES_DIR}/Image"
    efi_boot_name="BOOTAA64.EFI"
    cmdline_extra=" console=ttyAMA0,115200n8"
    oci_goarch="arm64"
    ;;
  *)
    echo "unknown TPMDD_ARCH: ${TPMDD_ARCH}" >&2
    exit 1
    ;;
esac

initrd="${TARGET_DIR}/usr/lib/modules/${kver}/initramfs.img"
rootfs_squashfs="${BINARIES_DIR}/rootfs.squashfs"
oci_archive="${BINARIES_DIR}/image.tar"
image_ref="latest"
target_imgref="${TPMDD_TARGET_IMGREF:-localhost/tpmdd:latest}"

test -f "${stub}"
test -f "${kernel}"
test -f "${initrd}"
test -f "${rootfs_squashfs}"

create_oci_archive() {
  local arch="$1"
  local -a layer_entries
  local tmp_dir layer layer_sha layer_size config config_sha config_size
  local devices_table users_table mkusers manifest manifest_sha manifest_size created

  created=$(date -u -d "@${SOURCE_DATE_EPOCH:-0}" +%Y-%m-%dT%H:%M:%SZ)
  tmp_dir=$(mktemp -d "${BINARIES_DIR}/oci.XXXXXX")

  mkdir -p "${tmp_dir}/blobs/sha256"
  layer="${tmp_dir}/layer.tar"
  devices_table="${BUILD_DIR}/buildroot-fs/full_devices_table.txt"
  users_table="${BUILD_DIR}/buildroot-fs/full_users_table.txt"
  mkusers="${PWD}/support/scripts/mkusers"
  test -r "${devices_table}"
  test -r "${users_table}"
  test -x "${mkusers}"

  mapfile -d '' -t layer_entries < <(
    find "${TARGET_DIR}" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z
  )

  # shellcheck disable=SC2016
  "${HOST_DIR}/bin/fakeroot" -- bash -c '
    set -euo pipefail
    target_dir="$1"
    layer="$2"
    users_table="$3"
    devices_table="$4"
    mkusers="$5"
    makedevs="$6"
    br2_config="$7"
    src_date_epoch="$8"
    shift 8
    chown -hR 0:0 "$target_dir"
    BR2_CONFIG="$br2_config" "$mkusers" "$users_table" "$target_dir"
    "$makedevs" -d "$devices_table" "$target_dir"
    tar \
      --sort=name \
      --mtime="@${src_date_epoch}" \
      --clamp-mtime \
      --numeric-owner \
      --acls \
      --xattrs \
      -C "$target_dir" \
      -cf "$layer" \
      "$@"
  ' _ "${TARGET_DIR}" "${layer}" "${users_table}" "${devices_table}" \
    "${mkusers}" "${HOST_DIR}/bin/makedevs" "${BR2_CONFIG}" \
    "${SOURCE_DATE_EPOCH:-0}" "${layer_entries[@]}"

  layer_sha=$(sha256sum "${layer}" | cut -d ' ' -f1)
  layer_size=$(stat -c %s "${layer}")
  mv "${layer}" "${tmp_dir}/blobs/sha256/${layer_sha}"

  config="${tmp_dir}/config.json"
  cat > "${config}" <<CFG
{"created":"${created}","architecture":"${arch}","os":"linux","config":{"Labels":{"containers.bootc":"1","ostree.bootable":"1","org.opencontainers.image.title":"tpmdd","org.opencontainers.image.version":"${TPMDD_VERSION}"}},"rootfs":{"type":"layers","diff_ids":["sha256:${layer_sha}"]},"history":[{"created":"${created}","created_by":"tpmdd post-image"}]}
CFG
  config_sha=$(sha256sum "${config}" | cut -d ' ' -f1)
  config_size=$(stat -c %s "${config}")
  mv "${config}" "${tmp_dir}/blobs/sha256/${config_sha}"

  manifest="${tmp_dir}/manifest.json"
  cat > "${manifest}" <<MAN
{"schemaVersion":2,"config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:${config_sha}","size":${config_size}},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:${layer_sha}","size":${layer_size}}]}
MAN
  manifest_sha=$(sha256sum "${manifest}" | cut -d ' ' -f1)
  manifest_size=$(stat -c %s "${manifest}")
  mv "${manifest}" "${tmp_dir}/blobs/sha256/${manifest_sha}"
  oci_digest="sha256:${manifest_sha}"

  cat > "${tmp_dir}/oci-layout" <<'LAY'
{"imageLayoutVersion":"1.0.0"}
LAY
  cat > "${tmp_dir}/index.json" <<IDX
{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:${manifest_sha}","size":${manifest_size},"annotations":{"org.opencontainers.image.ref.name":"${image_ref}"}}]}
IDX

  rm -f "${oci_archive}"
  tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH:-0}" \
    --clamp-mtime \
    --numeric-owner \
    -C "${tmp_dir}" \
    -cf "${oci_archive}" \
    oci-layout index.json blobs
  rm -rf "${tmp_dir}"
}

create_oci_archive "${oci_goarch}"

# bootc container lint: same-arch chroot, else qemu-user if present.
bootc_bin="${TARGET_DIR}/usr/bin/bootc"
case "${TPMDD_ARCH}" in
  amd64) bootc_host_arch=x86_64; qemu_user="${HOST_DIR}/bin/qemu-x86_64" ;;
  arm64) bootc_host_arch=aarch64; qemu_user="${HOST_DIR}/bin/qemu-aarch64" ;;
  *) bootc_host_arch=""; qemu_user="" ;;
esac
if [ ! -x "${bootc_bin}" ]; then
  echo "warning: skipping bootc container lint: ${bootc_bin} missing" >&2
elif [ "$(uname -m)" = "${bootc_host_arch}" ]; then
  if unshare --user --map-root-user true 2>/dev/null; then
    unshare --user --map-root-user --pid --fork --mount \
      bash -c '
        set -euo pipefail
        mount -t proc proc "'"${TARGET_DIR}"'/proc"
        chroot "'"${TARGET_DIR}"'" bootc container lint
      ' || echo "warning: bootc container lint failed" >&2
  else
    echo "warning: skipping bootc container lint: user namespaces are unavailable" >&2
  fi
elif [ -n "${qemu_user}" ] && [ -x "${qemu_user}" ]; then
  "${qemu_user}" -L "${TARGET_DIR}" "${bootc_bin}" \
    container lint --rootfs "${TARGET_DIR}" \
    || echo "warning: bootc container lint failed" >&2
else
  echo "warning: skipping bootc container lint: cannot run target bootc on host" >&2
fi

printf '{"imgref":"oci:%s","target_imgref":"%s","digest":"%s","version":"%s"}\n' \
  "${image_ref}" "${target_imgref}" "${oci_digest}" "${TPMDD_VERSION}" \
  > "${BINARIES_DIR}/image.manifest"
ln -sf image.tar "${BINARIES_DIR}/image-${TPMDD_VERSION}.tar"
ln -sf image.manifest "${BINARIES_DIR}/image-${TPMDD_VERSION}.manifest"

printf -v os_release '%s\n' \
  'NAME=tpmdd' \
  'ID=tpmdd' \
  "VERSION=\"${TPMDD_VERSION}\"" \
  "VERSION_ID=${TPMDD_VERSION}" \
  "PRETTY_NAME=\"linux-tpmdd ${TPMDD_VERSION} live test image\"" \
  'IMAGE_ID=tpmdd' \
  "IMAGE_VERSION=${TPMDD_VERSION}"

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
  cat >"${efi_part}.new/loader/loader.conf" <<'LOADER'
timeout 0
LOADER
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

  cat >"${stage}/config.txt" <<'CFG'
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

SSH_DIR="${TARGET_DIR}/var/roothome/.ssh"
sed -e "s|@IDENTITY_FILE@|${SSH_DIR}/id-rsa|g" \
  <"${BOARD_DIR}/ssh_config.in" \
  >"${BINARIES_DIR}/ssh_config"
