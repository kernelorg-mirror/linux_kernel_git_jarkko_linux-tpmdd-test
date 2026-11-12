#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${TPMDD_ARCH:?TPMDD_ARCH must be set (amd64 or arm64)}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by Buildroot}"
export SOURCE_DATE_EPOCH TZ=UTC
export PATH="${HOST_DIR}/bin:${HOST_DIR}/sbin:${PATH}"

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
. scripts/image-lib.sh

state_helper="${PWD}/scripts/state.py"
oci_source="${BINARIES_DIR}/rootfs-oci-latest-${TPMDD_ARCH}-linux.oci-image.tar"
image_ref=latest
tpmdd_version="${TPMDD_VERSION:-0}"
target_imgref="${TPMDD_TARGET_IMGREF:-localhost/tpmdd:latest}"

work=$(mktemp -d "${BINARIES_DIR}/image-manifest.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "${work}/new"

cp --reflink=auto "${oci_source}" "${work}/new/image.tar"
oci_digest=$(python3 "${state_helper}" oci-digest "${work}/new/image.tar")
python3 -c '
import json, sys
print(json.dumps(dict(zip(("imgref", "target_imgref", "digest", "version"), sys.argv[1:])),
                 separators=(",", ":")))
' "oci:${image_ref}" "${target_imgref}" "${oci_digest}" "${tpmdd_version}" \
  > "${work}/new/image.manifest"
ln -s image.tar "${work}/new/image-${tpmdd_version}.tar"
ln -s image.manifest "${work}/new/image-${tpmdd_version}.manifest"

for name in \
  image.tar \
  image.manifest \
  "image-${tpmdd_version}.tar" \
  "image-${tpmdd_version}.manifest"; do
  mv -fT "${work}/new/${name}" "${BINARIES_DIR}/${name}"
done
