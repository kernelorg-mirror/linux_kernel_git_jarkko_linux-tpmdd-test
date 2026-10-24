#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

rootfs=$1
stage=$2
output=$3
digest=$4
archive=$5
installer_config=$6
live_ssh=$7

unsquashfs -quiet -d "${stage}" "${rootfs}"
sed -i 's/^root:[^:]*:/root::/' "${stage}/etc/shadow"
install -d -m 0700 "${stage}/var/roothome/.ssh"
install -m 0600 "${live_ssh}/id-rsa" "${stage}/var/roothome/.ssh/id-rsa"
install -m 0644 "${live_ssh}/id-rsa.pub" "${stage}/var/roothome/.ssh/id-rsa.pub"
install -m 0600 "${live_ssh}/id-rsa.pub" "${stage}/var/roothome/.ssh/authorized_keys"
chown -R 0:0 "${stage}/var/roothome/.ssh"
install -d "${stage}/usr/share/tpmdd"
sed "s/@OCI_DIGEST@/${digest}/" "${installer_config}" \
  > "${stage}/usr/share/tpmdd/installer.yaml"
chown -R 0:0 "${stage}/usr/share/tpmdd"
touch -d "@${SOURCE_DATE_EPOCH}" \
  "${stage}/usr/share/tpmdd" "${stage}/usr/share/tpmdd/installer.yaml" \
  "${stage}/etc/shadow"
mksquashfs "${stage}" "${output}" -noappend -comp gzip
