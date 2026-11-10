#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${BINARIES_DIR:?BINARIES_DIR must be set by Buildroot}"
: "${HOST_DIR:?HOST_DIR must be set by Buildroot}"
: "${BR2_EXTERNAL_TPMDD_PATH:?BR2_EXTERNAL_TPMDD_PATH must be set by Buildroot}"
: "${TPMDD_ARCH:?TPMDD_ARCH must be set (amd64 or arm64)}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by Buildroot}"
export SOURCE_DATE_EPOCH TZ=UTC
export PATH="${HOST_DIR}/bin:${HOST_DIR}/sbin:${PATH}"

cd -- "${BR2_EXTERNAL_TPMDD_PATH}"
. scripts/image-lib.sh

state_helper="${BR2_EXTERNAL_TPMDD_PATH}/scripts/state.py"
state="${BINARIES_DIR}/.image-manifest.state"
oci_source="${BINARIES_DIR}/rootfs-oci-latest-${TPMDD_ARCH}-linux.oci-image.tar"
image_ref=latest
tpmdd_version="${TPMDD_VERSION:-0}"
target_imgref="${TPMDD_TARGET_IMGREF:-localhost/tpmdd:latest}"

inputs=(
  --value "arch=${TPMDD_ARCH}"
  --value "epoch=${SOURCE_DATE_EPOCH}"
  --value "version=${tpmdd_version}"
  --value "target_imgref=${target_imgref}"
)
for path in \
  "${BR2_EXTERNAL_TPMDD_PATH}/scripts/image-manifest.sh" \
  "${BR2_EXTERNAL_TPMDD_PATH}/scripts/image-lib.sh" \
  "${state_helper}" \
  "${oci_source}"; do
  resolved=$(realpath -e "${path}")
  inputs+=(--path "${path}")
  [[ "${path}" == "${resolved}" ]] || inputs+=(--path "${resolved}")
done

key=$(python3 "${state_helper}" key "${inputs[@]}")
outputs=(
  --metadata-path "${BINARIES_DIR}/image.tar"
  --path "${BINARIES_DIR}/image.manifest"
  --path "${BINARIES_DIR}/image-${tpmdd_version}.tar"
  --path "${BINARIES_DIR}/image-${tpmdd_version}.manifest"
)
if python3 "${state_helper}" check "${state}" --key "${key}" "${outputs[@]}"; then
  echo "image manifest is up to date"
  exit 0
else
  status=$?
  [[ "${status}" == 1 ]] || exit "${status}"
fi

work=$(mktemp -d "${BINARIES_DIR}/image-manifest.XXXXXX")
updated=()
record=
committed=0
trap '
  if [[ "${committed}" == 0 ]]; then
    for record in "${updated[@]}"; do
      existed="${record%%:*}"
      name="${record#*:}"
      rm -rf -- "${BINARIES_DIR:?}/${name:?}"
      if [[ "${existed}" == 1 ]]; then
        mv -T "${work}/old/${name}" "${BINARIES_DIR}/${name}"
      fi
    done
  fi
  rm -rf -- "${work}"
' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "${work}/new" "${work}/old"

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
  existed=0
  if [[ -e "${BINARIES_DIR}/${name}" || -L "${BINARIES_DIR}/${name}" ]]; then
    existed=1
    ln -P "${BINARIES_DIR}/${name}" "${work}/old/${name}"
  fi
  updated+=("${existed}:${name}")
  mv -fT "${work}/new/${name}" "${BINARIES_DIR}/${name}"
done

python3 "${state_helper}" save "${state}" --key "${key}" "${outputs[@]}"
committed=1
