#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

SSH_DIR="${TARGET_DIR}/root/.ssh"
echo "SSH_DIR=$SSH_DIR"

mkdir -p -m 700 "$SSH_DIR"

if [ ! -f "$SSH_DIR/id-rsa" ]; then
  ssh-keygen -C 'root@tpmdd' -t rsa -f "$SSH_DIR/id-rsa" -N ''
  cp -f "$SSH_DIR"/{id-rsa.pub,authorized_keys}
  chmod 600 "$SSH_DIR/authorized_keys"
fi

GETTY_WANTS_DIR="${TARGET_DIR}/etc/systemd/system/getty.target.wants"
SERIAL_GETTY_WANTS_DIR="${TARGET_DIR}/etc/systemd/system/serial-getty.target.wants"

mkdir -p "$GETTY_WANTS_DIR" "$SERIAL_GETTY_WANTS_DIR"
ln -sf /usr/lib/systemd/system/getty@.service \
  "${GETTY_WANTS_DIR}/getty@tty1.service"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  "${SERIAL_GETTY_WANTS_DIR}/serial-getty@ttyS0.service"

# WiFi (optional: set WIRELESS_SSID and WIRELESS_PASSWORD env vars)
if [ -n "$WIRELESS_SSID" ] && [ -n "$WIRELESS_PASSWORD" ]; then
  WPA_DIR="${TARGET_DIR}/etc/wpa_supplicant"
  mkdir -p "$WPA_DIR"
  printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n\nnetwork={\n\tssid="%s"\n\tpsk="%s"\n}\n' \
    "$WIRELESS_SSID" "$WIRELESS_PASSWORD" > "$WPA_DIR/wpa_supplicant-wlan0.conf"
  chmod 600 "$WPA_DIR/wpa_supplicant-wlan0.conf"

  NETWORK_DIR="${TARGET_DIR}/etc/systemd/network"
  mkdir -p "$NETWORK_DIR"
  cat > "$NETWORK_DIR/25-wireless.network" <<'EOF'
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF

  WPA_UNIT="${TARGET_DIR}/usr/lib/systemd/system/wpa_supplicant@.service"
  if [ ! -f "$WPA_UNIT" ]; then
    cat > "$WPA_UNIT" <<'EOF'
[Unit]
Description=WPA supplicant (%i)
Requires=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=simple
ExecStart=/usr/sbin/wpa_supplicant -c/etc/wpa_supplicant/wpa_supplicant-%I.conf -i%I

[Install]
WantedBy=multi-user.target
EOF
  fi

  mkdir -p "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/wpa_supplicant@.service \
    "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"
fi

FW_DIR="${TARGET_DIR}/lib/firmware/brcm"

if [ -d "$FW_DIR" ] && [ -e "$FW_DIR/brcmfmac43456-sdio.bin" ]; then
  ln -sf brcmfmac43456-sdio.bin "$FW_DIR/brcmfmac43456-sdio.raspberrypi,400.bin"
  ln -sf brcmfmac43456-sdio.clm_blob "$FW_DIR/brcmfmac43456-sdio.raspberrypi,400.clm_blob"
  ln -sf brcmfmac43456-sdio.txt "$FW_DIR/brcmfmac43456-sdio.raspberrypi,400.txt"
fi
