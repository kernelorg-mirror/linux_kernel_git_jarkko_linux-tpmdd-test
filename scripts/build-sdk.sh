#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

set -euo pipefail

if (($# != 11)); then
  echo "usage: $0 <arch> <defconfig> <tarball> <hash> <build_root> <src_dir> <install_root> <lock> <dl_dir> <ccache_dir> <epoch>" >&2
  exit 1
fi

arch=$1
defconfig=$2
tarball=$3
hash=$4
sdk_build_dir=$5
src_dir=$6
sdk_install_root=$7
sdk_lock=$8
dl_dir=$9
ccache_dir=${10}
epoch=${11}

make_flags=${MAKEFLAGS-}
if [[ ${make_flags%% *} == *n* ]]; then
  exit 0
fi

mkdir -p "$(dirname "$sdk_lock")"
exec 9>"$sdk_lock"
flock 9

install_stamp="${sdk_install_root}/.stamp/${arch}/install"
if [[ -e "$install_stamp" ]]; then
  exit 0
fi

build_dir="${sdk_build_dir}/build/${arch}"
build_stamp="${sdk_build_dir}/.stamp/${arch}/build"
if [[ ! -e "$build_stamp" ]]; then
  echo "$hash  $tarball" | sha256sum --status -c -

  unpack_stamp="${sdk_build_dir}/.stamp/unpack"
  if [[ ! -e "$unpack_stamp" ]]; then
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    tar -xf "$tarball" --strip-components=1 -C "$src_dir"
    mkdir -p "$(dirname "$unpack_stamp")"
    touch "$unpack_stamp"
  fi

  mkdir -p "$build_dir"
  make_args=(
    -C "$src_dir" O="$build_dir"
    BR2_DL_DIR="$dl_dir" BR2_CCACHE_DIR="$ccache_dir"
    SOURCE_DATE_EPOCH="$epoch"
  )
  "${MAKE:-make}" "${make_args[@]}" defconfig DEFCONFIG="$defconfig"
  "${MAKE:-make}" "${make_args[@]}" sdk
  mkdir -p "$(dirname "$build_stamp")"
  touch "$build_stamp"
fi

shopt -s nullglob
tarballs=("$build_dir/images/"*_sdk-buildroot.tar.gz)
if ((${#tarballs[@]} != 1)); then
  echo "error: expected one SDK tarball in $build_dir/images, found ${#tarballs[@]}" >&2
  exit 1
fi
sdk_archive=${tarballs[0]}
topdir="$(basename "$sdk_archive" .tar.gz)"

dest_dir="${sdk_install_root}/${arch}"
rm -rf "$dest_dir"
mkdir -p "$dest_dir"
tar -xzf "$sdk_archive" -C "$dest_dir"

relocate_script="${dest_dir}/${topdir}/relocate-sdk.sh"
if [[ ! -x "$relocate_script" ]]; then
  echo "error: relocate-sdk.sh not found or not executable in $dest_dir/$topdir" >&2
  exit 1
fi
"$relocate_script"

mkdir -p "$(dirname "$install_stamp")"
touch "$install_stamp"
