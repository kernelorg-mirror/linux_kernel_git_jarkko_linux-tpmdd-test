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
grep -q '^PUU_INSTALLER_CONFIG=' "${stage}/etc/environment" 2>/dev/null ||
  printf 'PUU_INSTALLER_CONFIG=/usr/share/tpmdd/installer.yaml\n' \
    >> "${stage}/etc/environment"
pam_config="${stage}/etc/pam.d/system-auth"
test -f "${pam_config}"
grep -q pam_env.so "${pam_config}" ||
  printf 'session  required pam_env.so\n' >> "${pam_config}"
install -d -m 0755 "${stage}/etc/sudoers.d"
printf 'Defaults env_file=/etc/environment\n' \
  > "${stage}/etc/sudoers.d/30-tpmdd-installer"
chmod 0440 "${stage}/etc/sudoers.d/30-tpmdd-installer"
chown 0:0 "${stage}/etc/sudoers.d/30-tpmdd-installer"
chown -R 0:0 "${stage}/usr/share/tpmdd"
touch -d "@${SOURCE_DATE_EPOCH}" \
  "${stage}/usr/share/tpmdd" "${stage}/usr/share/tpmdd/installer.yaml" \
  "${stage}/etc/shadow" \
  "${stage}/etc/environment" "${stage}/etc/pam.d/system-auth" \
  "${stage}/etc/sudoers.d/30-tpmdd-installer"
mksquashfs "${stage}" "${output}" -noappend -comp gzip
