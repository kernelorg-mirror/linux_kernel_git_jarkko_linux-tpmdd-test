#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>
set -e

cd "${0%/*}"

# The architecture is derived from the ISO present in this directory: each
# board build produces its own images directory.
if [ -f tpmdd_amd64.iso ]; then
  TPMDD_ARCH=amd64
elif [ -f tpmdd_arm64.iso ]; then
  TPMDD_ARCH=arm64
else
  echo "error: neither tpmdd_amd64.iso nor tpmdd_arm64.iso found" >&2
  exit 1
fi

swtpm_dir=$(mktemp -d -t swtpm-XXXXXX)
swtpm_state_dir="$swtpm_dir/state"
swtpm_conf_dir="$swtpm_dir/config"
swtpm_localca_dir="$swtpm_dir/localca"

cleanup() {
  kill -- "$(cat "$swtpm_dir/swtpm.pid" 2>/dev/null)" 2>/dev/null || true
  if [ -n "${qemu_pid:-}" ]; then
    kill "$qemu_pid" 2>/dev/null || true
  fi
  rm -rf "$swtpm_dir"
}
trap cleanup EXIT

opt_serial_socket=false
QEMU_TPM_DEVICE="tpm-tis"
SWTPM_TPM2="--tpm2"
gdb_port=""

case "${TPMDD_ARCH}" in
  amd64)
    QEMU_TPM_DEVICE="tpm-tis"
    ;;
  arm64)
    QEMU_TPM_DEVICE="tpm-tis-device"
    ;;
esac

while [ "$1" ]; do
  case "$1" in
  --tpm-crb)
    [ "${TPMDD_ARCH}" = amd64 ] || {
      echo "error: --tpm-crb is only supported on amd64" >&2
      exit 1
    }
    QEMU_TPM_DEVICE="tpm-crb"; shift;;
  --tpm1) SWTPM_TPM2=""; shift;;
  --gdb) gdb_port="1234"; shift;;
  --gdb=*) gdb_port="${1#--gdb=}"; shift;;
  --serial-socket) opt_serial_socket=true; shift;;
  --) shift; break;;
  *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

extra_args=("$@")
case "${TPMDD_ARCH}" in
  amd64)
    extra_args+=(
      "-device" "virtio-vga-gl,hostmem=2G,blob=true,venus=true"
      "-device" "virtio-serial-pci"
      "-chardev" "spicevmc,id=vdagent0,name=vdagent"
      "-device" "virtserialport,chardev=vdagent0,name=com.redhat.spice.0"
      "-display" "gtk,gl=on"
    )
    ;;
  arm64)
    extra_args+=(
      "-device" "virtio-gpu-pci"
      "-device" "virtio-serial-pci"
      "-display" "gtk"
    )
    ;;
esac

if [[ -n "$gdb_port" ]]; then
  extra_args+=("-S" "-gdb" "tcp::${gdb_port}")
fi

if $opt_serial_socket; then
  extra_args+=("-serial" "unix:serial.sock,server,wait")
fi

mkdir -p "$swtpm_state_dir" "$swtpm_conf_dir" "$swtpm_localca_dir"
chmod 700 "$swtpm_state_dir" "$swtpm_localca_dir"

cat >"$swtpm_conf_dir/swtpm-localca.conf" <<EOF
statedir = $swtpm_localca_dir
signingkey = $swtpm_localca_dir/signkey.pem
issuercert = $swtpm_localca_dir/issuercert.pem
certserial = $swtpm_localca_dir/certserial
EOF

cat >"$swtpm_conf_dir/swtpm-localca.options" <<'EOF'
--platform-manufacturer Buildroot
--platform-version 0
--platform-model QEMU
EOF

cat >"$swtpm_conf_dir/swtpm_setup.conf" <<EOF
create_certs_tool = swtpm_localca
create_certs_tool_config = $swtpm_conf_dir/swtpm-localca.conf
create_certs_tool_options = $swtpm_conf_dir/swtpm-localca.options
EOF

swtpm_setup_args=(
  --tpmstate "$swtpm_state_dir"
  --create-ek-cert
  --overwrite
  --config "$swtpm_conf_dir/swtpm_setup.conf"
)
if [ -n "$SWTPM_TPM2" ]; then
  swtpm_setup_args+=(--tpm2 --allow-signing)
else
  swtpm_setup_args+=(--take-ownership --owner-well-known --srk-well-known)
fi
swtpm_setup "${swtpm_setup_args[@]}"

swtpm socket \
  --tpmstate dir="$swtpm_state_dir" \
  --ctrl type=unixio,path="$swtpm_dir/swtpm-sock" \
  --pid file="$swtpm_dir/swtpm.pid" \
  --log file=swtpm.log,level=20 ${SWTPM_TPM2} -d

case "${TPMDD_ARCH}" in
  amd64)
    qemu-system-x86_64 \
      -M pc \
      -m 1G \
      -monitor unix:monitor.sock,server,nowait \
      -drive file=tpmdd_amd64.iso,if=virtio,format=raw,readonly=on \
      -netdev user,id=net0,hostfwd=tcp::10022-:22 \
      -device virtio-net-pci,netdev=net0 \
      -rtc base=localtime \
      -chardev socket,id=chrtpm,path="$swtpm_dir/swtpm-sock" \
      -tpmdev emulator,id=tpm0,chardev=chrtpm \
      -device ${QEMU_TPM_DEVICE},tpmdev=tpm0 \
      -drive if=pflash,format=raw,file="$PWD/OVMF_CODE.fd",readonly=on \
      -drive if=pflash,format=raw,file="$PWD/OVMF_VARS.fd" \
      "${extra_args[@]}" <&0 &
    ;;
  arm64)
    qemu-system-aarch64 \
      -M virt \
      -cpu cortex-a72 \
      -m 1G \
      -monitor unix:monitor.sock,server,nowait \
      -drive file=tpmdd_arm64.iso,if=virtio,format=raw,readonly=on \
      -netdev user,id=net0,hostfwd=tcp::10022-:22 \
      -device virtio-net-pci,netdev=net0 \
      -rtc base=localtime \
      -chardev socket,id=chrtpm,path="$swtpm_dir/swtpm-sock" \
      -tpmdev emulator,id=tpm0,chardev=chrtpm \
      -device ${QEMU_TPM_DEVICE},tpmdev=tpm0 \
      -bios QEMU_EFI.fd \
      "${extra_args[@]}" <&0 &
    ;;
esac
qemu_pid=$!
echo "$qemu_pid" > qemu.pid
wait "$qemu_pid"
