#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

CONTAINER=${CONTAINER:-docker}
CONTAINER_CPUS=${CONTAINER_CPUS:-8}
CONTAINER_MEMORY=${CONTAINER_MEMORY:-16G}

build_args=(--tag tpmdd-builder:latest)
if [ "$(basename -- "${CONTAINER}")" = container ]; then
  build_args=(
    --cpus "${CONTAINER_CPUS}"
    --memory "${CONTAINER_MEMORY}"
    "${build_args[@]}"
  )
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

for volume in tpmdd-build tpmdd-cache; do
  "${CONTAINER}" volume inspect "${volume}" >/dev/null 2>&1 ||
    "${CONTAINER}" volume create "${volume}" >/dev/null
done

run_args=(--env OUTPUT_DIR=/build)
for var in TPMDD_VERSION TPMDD_TARGET_IMGREF; do
  if [ "${!var+x}" = x ]; then
    run_args+=(--env "${var}")
  fi
done

"${CONTAINER}" build "${build_args[@]}" .

"${CONTAINER}" run \
  -d \
  --init \
  --cpus "${CONTAINER_CPUS}" \
  --memory "${CONTAINER_MEMORY}" \
  "${run_args[@]}" \
  --volume "${PWD}:/workspace" \
  --volume tpmdd-build:/build \
  --volume tpmdd-cache:/cache \
  tpmdd-builder:latest
