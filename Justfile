# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set shell := ["bash", "-euo", "pipefail", "-c"]

buildroot_version := "8e786e873ac759b5804059e8ae750e51c3a006ca"
buildroot_hash    := "14bca416698d21e57f03eecf491339679ac8446839f9b23af172c56acd81acff"
buildroot_site    := "https://github.com/buildroot/buildroot/archive" / (buildroot_version + ".tar.gz")

buildroot_cache         := cache_directory() / "tpmdd" / "buildroot"
buildroot_download_dir  := buildroot_cache / "download"
buildroot_tarball       := buildroot_download_dir / "buildroot-" + buildroot_version + ".tar.gz"

build_dir := "build"

# List available recipes.
default:
  @just --list --unsorted

# List available targets.
list:
  @cd "{{ justfile_directory() }}"/configs && ls *_defconfig | sed 's/_defconfig//'

# Configure target.
configure target: (dependencies target) (patch target)
  @path_abs="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}"; \
  stamp_dir="$path_abs/stamp"; \
  configure_stamp="$stamp_dir/.configured"; \
  if [ -f "$configure_stamp" ]; then exit 0; fi; \
  mkdir -p "$path_abs" "$stamp_dir"; \
  make -C "$path_abs/src/buildroot-{{ buildroot_version }}" O="$path_abs" \
    BR2_EXTERNAL="{{ justfile_directory() }}" \
    BR2_DL_DIR="{{ buildroot_download_dir }}" \
    {{ target }}_defconfig; \
  touch "$configure_stamp"

# Build target.
build target: (configure target)
  @path_abs="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}"; \
  make -C "$path_abs/src/buildroot-{{ buildroot_version }}" O="$path_abs" \
    BR2_EXTERNAL="{{ justfile_directory() }}" \
    BR2_DL_DIR="{{ buildroot_download_dir }}" \
    -j$(nproc)

# Burn the target disk image to a block device.
burn target device: (build target)
  @if [ ! -b "{{ device }}" ]; then \
    echo "error: {{ device }} is not a block device" >&2; \
    exit 1; \
  fi
  @sudo dd if="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}/images/disk.img" \
    of="{{ device }}" bs=1M status=progress oflag=sync

# Delete build artifacts.
clean:
  rm -rf {{ build_dir }}

[private]
download target:
  @stamp="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}/stamp/.downloaded"; \
  if [ -f "$stamp" ]; then exit 0; fi; \
  mkdir -p "{{ buildroot_cache }}" "{{ buildroot_download_dir }}"; \
  if [ ! -f "{{ buildroot_tarball }}" ]; then \
    wget -q --show-progress -O "{{ buildroot_tarball }}.partial" "{{ buildroot_site }}"; \
    mv "{{ buildroot_tarball }}.partial" "{{ buildroot_tarball }}"; \
  fi; \
  mkdir -p "$(dirname "$stamp")"; \
  touch "$stamp"

[private]
verify target: (download target)
  @stamp="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}/stamp/.verified"; \
  if [ -f "$stamp" ]; then exit 0; fi; \
  echo "{{ buildroot_hash }}  {{ buildroot_tarball }}" | sha256sum --status -c -; \
  mkdir -p "$(dirname "$stamp")"; \
  touch "$stamp"

[private]
unpack target: (verify target)
  @path_abs="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}"; \
  src_dir="$path_abs/src/buildroot-{{ buildroot_version }}"; \
  stamp_dir="$path_abs/stamp"; \
  stamp="$stamp_dir/.unpacked"; \
  if [ -f "$stamp" ]; then exit 0; fi; \
  mkdir -p "$src_dir"; \
  tar -xf "{{ buildroot_tarball }}" --strip-components=1 -C "$src_dir"; \
  mkdir -p "$stamp_dir"; \
  touch "$stamp"

[private]
patch target: (unpack target)
  @path_abs="{{ justfile_directory() }}/{{ build_dir }}/{{ target }}"; \
  src_dir="$path_abs/src/buildroot-{{ buildroot_version }}"; \
  stamp_dir="$path_abs/stamp"; \
  stamp="$stamp_dir/.patched"; \
  if [ -f "$stamp" ]; then exit 0; fi; \
  patches_dir="{{ justfile_directory() }}/patches/buildroot"; \
  if [ -d "$patches_dir" ]; then \
    for p in "$patches_dir"/*.patch; do \
      [ -f "$p" ] || continue; \
      patch -d "$src_dir" -p1 -i "$p"; \
    done; \
  fi; \
  mkdir -p "$stamp_dir"; \
  touch "$stamp"

[private]
dependencies target:
  @if [ ! -f "{{ justfile_directory() }}/configs/{{ target }}_defconfig" ]; then \
    echo "error: missing configs/{{ target }}_defconfig" >&2; \
    exit 1; \
  fi
