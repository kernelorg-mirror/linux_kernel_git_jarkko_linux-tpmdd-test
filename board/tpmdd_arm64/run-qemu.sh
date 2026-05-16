#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>
set -e

cd "${0%/*}/" || exit 1

swtpm_dir=$(mktemp -d -t swtpm-XXXXXX)
swtpm_state_dir="$swtpm_dir/state"
swtpm_conf_dir="$swtpm_dir/config"
swtpm_localca_dir="$swtpm_dir/localca"

function cleanup {
  kill -- "$(cat "$swtpm_dir/swtpm.pid" 2>/dev/null)" 2>/dev/null || true
  if (( $(jobs -p | wc -l) > 0 )); then
    kill "$(jobs -p)"
  fi
  rm -rf "$swtpm_dir"
}
trap cleanup EXIT

opt_graphics=false
opt_serial_socket=false
QEMU_TPM_DEVICE="tpm-tis-device"
SWTPM_TPM2="--tpm2"
gdb_port=""

while [ "$1" ]; do
  case "$1" in
  --graphics) opt_graphics=true; shift;;
  --tpm1) SWTPM_TPM2=""; shift;;
  --gdb) gdb_port="1234"; shift;;
  --gdb=*) gdb_port="${1#--gdb=}"; shift;;
  --serial-socket) opt_serial_socket=true; shift;;
  --) shift; break;;
  *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

extra_args=("$@")
if ! $opt_graphics; then
  extra_args+=("-nographic")
fi
if [[ -n "$gdb_port" ]]; then
  extra_args+=("-S" "-gdb" "tcp::${gdb_port}")
fi

if $opt_graphics; then
  extra_args+=("-device" "virtio-gpu-pci")
  extra_args+=("-device" "virtio-serial-pci")
  extra_args+=("-display" "gtk")
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

if [ -n "$SWTPM_TPM2" ]; then
  swtpm_setup \
    --tpm2 \
    --tpmstate "$swtpm_state_dir" \
    --create-ek-cert \
    --allow-signing \
    --overwrite \
    --config "$swtpm_conf_dir/swtpm_setup.conf"
else
  swtpm_setup \
    --tpmstate "$swtpm_state_dir" \
    --take-ownership \
    --owner-well-known \
    --srk-well-known \
    --create-ek-cert \
    --overwrite \
    --config "$swtpm_conf_dir/swtpm_setup.conf"
fi

swtpm socket \
  --tpmstate dir="$swtpm_state_dir" \
  --ctrl type=unixio,path="$swtpm_dir/swtpm-sock" \
  --pid file="$swtpm_dir/swtpm.pid" \
  --log file=swtpm.log,level=20 ${SWTPM_TPM2} -d

echo $$ > qemu.pid
exec qemu-system-aarch64 \
  -M virt \
  -cpu cortex-a72 \
  -m 1G \
  -monitor unix:monitor.sock,server,nowait \
  -drive file=disk.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp::10022-:22 \
  -device virtio-net-pci,netdev=net0 \
  -rtc base=localtime \
  -chardev socket,id=chrtpm,path="$swtpm_dir"/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device ${QEMU_TPM_DEVICE},tpmdev=tpm0 \
  -drive if=pflash,format=raw,file="$PWD/AAVMF_CODE.fd",readonly=on \
  -drive if=pflash,format=raw,file="$PWD/AAVMF_VARS.fd" \
  "${extra_args[@]}"
