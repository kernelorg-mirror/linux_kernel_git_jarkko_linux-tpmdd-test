#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -euo pipefail

: "${BOARD:?}"
: "${SDK_DEFCONFIG:?}"
: "${SDK_HOST_ID:?}"
: "${SDK_HOST_LIBC:?}"
: "${SDK_HOST_CC:?}"
: "${SDK_HOST_BINUTILS:?}"
: "${SDK_CACHE_DIR:?}"
: "${SDK_ARCHIVE:?}"
: "${SDK_CHECKSUM:?}"
: "${SDK_METADATA:?}"
: "${SDK_KEY:?}"
: "${PATCH_STAMP:?}"
: "${SDK_BUILD_DIR:?}"
: "${SDK_NAME:?}"
: "${BUILDROOT_VERSION:?}"
: "${BUILDROOT_HASH:?}"
: "${SOURCE_DATE_EPOCH:?}"
: "${BOARD_DIR:?}"
: "${CURDIR:?}"
: "${CCACHE_DIR:?}"
: "${DOWNLOAD_DIR:?}"
: "${TPMDD_VERSION:?}"
: "${MAKE:=make}"

test -f "${SDK_DEFCONFIG}" || {
	echo "error: unsupported SDK board: ${BOARD}" >&2
	exit 2
}
command -v cc cmp getconf ld flock sha256sum >/dev/null || {
	echo "error: unable to identify or cache the SDK host toolchain" >&2
	exit 1
}
test -n "${SDK_HOST_LIBC}" && test -n "${SDK_HOST_CC}" && test -n "${SDK_HOST_BINUTILS}" || {
	echo "error: unable to identify SDK host toolchain" >&2
	exit 1
}

mkdir -p "$(dirname "${SDK_CACHE_DIR}")"
exec 9>"${SDK_CACHE_DIR}.lock"
flock 9

if [ -d "${SDK_CACHE_DIR}" ]; then
	if [ ! -f "${SDK_ARCHIVE}" ] || [ ! -f "${SDK_CHECKSUM}" ] || [ ! -f "${SDK_METADATA}" ]; then
		echo "error: incomplete SDK cache: ${SDK_CACHE_DIR}" >&2
		exit 1
	fi
	if ! { 
		printf '%s\n' \
			"buildroot-version=${BUILDROOT_VERSION}" \
			"buildroot-hash=${BUILDROOT_HASH}" \
			"source-date-epoch=${SOURCE_DATE_EPOCH}" \
			"host=${SDK_HOST_ID}" \
			"host-libc=${SDK_HOST_LIBC}" \
			"host-cc=${SDK_HOST_CC}" \
			"host-binutils=${SDK_HOST_BINUTILS}" \
			"board=${BOARD}" \
			"key=${SDK_KEY}"
	} | cmp -s - "${SDK_METADATA}"; then
		echo "error: mismatched SDK cache metadata: ${SDK_METADATA}" >&2
		exit 1
	fi
	if ! (cd "${SDK_CACHE_DIR}" && sha256sum --status -c "$(basename "${SDK_CHECKSUM}")"); then
		echo "error: corrupt SDK cache: ${SDK_ARCHIVE}" >&2
		exit 1
	fi
	echo "Using cached SDK: ${SDK_ARCHIVE}"
	exit 0
fi

if [ -e "${SDK_CACHE_DIR}" ]; then
	echo "error: SDK cache path is not a directory: ${SDK_CACHE_DIR}" >&2
	exit 1
fi

echo "Generating SDK: ${SDK_ARCHIVE}"
"${MAKE}" "${PATCH_STAMP}" BOARD="${BOARD}"

sdk_build="${SDK_BUILD_DIR}"
cache_tmp="${SDK_CACHE_DIR}.partial.$$"
trap 'rm -rf "${sdk_build}" "${cache_tmp}"' EXIT

rm -rf "${sdk_build}" "${cache_tmp}"
mkdir -p "${sdk_build}" "${cache_tmp}"

buildroot_at() {
	local out=$1
	shift
	"${MAKE}" -C "${BOARD_DIR}/src/buildroot-${BUILDROOT_VERSION}" O="${out}" \
		BR2_REPRODUCIBLE=y BR2_EXTERNAL="${CURDIR}" \
		BR2_CCACHE_DIR="${CCACHE_DIR}" BR2_DL_DIR="${DOWNLOAD_DIR}" \
		SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
		TPMDD_SDK_ARCHIVE="${SDK_ARCHIVE}" TPMDD_VERSION="${TPMDD_VERSION}" \
		"$@"
}

buildroot_at "${sdk_build}" BR2_DEFCONFIG="${SDK_DEFCONFIG}" defconfig
buildroot_at "${sdk_build}" sdk

shopt -s nullglob
archives=("${sdk_build}"/images/*_sdk-buildroot.tar.gz)
if [ "${#archives[@]}" -ne 1 ]; then
	echo "error: expected one SDK archive, found ${#archives[@]}" >&2
	exit 1
fi

cp "${archives[0]}" "${cache_tmp}/${SDK_NAME}"
(
	cd "${cache_tmp}"
	sha256sum "${SDK_NAME}" > "$(basename "${SDK_CHECKSUM}")"
)

printf '%s\n' \
	"buildroot-version=${BUILDROOT_VERSION}" \
	"buildroot-hash=${BUILDROOT_HASH}" \
	"source-date-epoch=${SOURCE_DATE_EPOCH}" \
	"host=${SDK_HOST_ID}" \
	"host-libc=${SDK_HOST_LIBC}" \
	"host-cc=${SDK_HOST_CC}" \
	"host-binutils=${SDK_HOST_BINUTILS}" \
	"board=${BOARD}" \
	"key=${SDK_KEY}" \
	> "${cache_tmp}/$(basename "${SDK_METADATA}")"

mv -T "${cache_tmp}" "${SDK_CACHE_DIR}"
rm -rf "${sdk_build}"
trap - EXIT