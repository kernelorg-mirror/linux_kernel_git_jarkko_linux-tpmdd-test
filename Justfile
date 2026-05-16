# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set shell := ["bash", "-euo", "pipefail", "-c"]

buildroot_version := "8e786e873ac759b5804059e8ae750e51c3a006ca"
buildroot_hash    := "14bca416698d21e57f03eecf491339679ac8446839f9b23af172c56acd81acff"
buildroot_site    := "https://github.com/buildroot/buildroot/archive" / (buildroot_version + ".tar.gz")

cache_dir         := cache_directory() / "tpmdd"
download_dir      := cache_dir / "download"
ccache_dir        := cache_dir / "ccache"
build_dir         := env_var_or_default("BUILD", "build")
source_dir        := build_dir / "src" / ("buildroot-" + buildroot_version)
stamp_dir         := build_dir / "stamp"

target_file       := build_dir / "target"
buildroot_file    := download_dir / "buildroot" / "buildroot-" + buildroot_version + ".tar.gz"
 
download_stamp    := stamp_dir / ".downloaded"
verify_stamp      := stamp_dir / ".verified"
unpack_stamp      := stamp_dir / ".unpacked"
patch_stamp       := stamp_dir / ".patched"
configure_stamp   := stamp_dir / ".configured"

# List available recipes.
default:
  @just --list --unsorted

# Configure build target
configure target: (dependencies target) patch
  @if [ -f "{{ configure_stamp }}" ] && [ -f "{{ target_file }}" ] && \
     read -r prev < "{{ target_file }}" && [ "$prev" = "{{ target }}" ]; then exit 0; \
  fi; \
  rm -vf "{{ configure_stamp }}"; \
  rm -vf "{{ target_file }}"; \
  path_abs="{{ absolute_path(build_dir) }}/{{ target }}"; \
  mkdir -p "$path_abs"; \
  make -C "{{source_dir}}" O="$path_abs" \
    BR2_EXTERNAL="{{ justfile_directory() }}" \
    BR2_DL_DIR="{{ download_dir }}" \
    {{ target }}_defconfig; \
  printf '%s\n' "{{ target }}" > "{{ target_file }}"; \
  touch "{{ configure_stamp }}"

# Build the disk image.
build:
  @if [ ! -f "{{ configure_stamp }}" ]; then \
    echo "ERROR: prepare first." >&2; \
    exit 1; \
  fi
  read -r target < "{{ target_file }}"; \
  make BR2_DL_DIR="{{ download_dir }}" \
    -C "{{ source_dir }}" O="{{ absolute_path(build_dir) }}/$target" \
    BR2_EXTERNAL="{{ justfile_directory() }}" \
    V=0

# Burn the disk image.
burn device: build
  @if [ ! -b "{{ device }}" ]; then \
    echo "ERROR: {{ device }} is not a block device." >&2; \
    exit 1; \
  fi
  read -r target < "{{ target_file }}"; \
  sudo dd if="{{ absolute_path(build_dir) }}/$target/images/disk.img" of="{{ device }}" bs=1M status=progress oflag=sync

# Delete build artifacts.
clean:
  rm -rf "{{ build_dir }}"

[private]
patch: unpack
  @if [ -f "{{ patch_stamp }}" ]; then exit 0; fi; \
  patches_dir="{{ justfile_directory() }}/patches/buildroot"; \
  if [ -d "$patches_dir" ]; then \
    for p in "$patches_dir"/*.patch; do \
      [ -f "$p" ] || continue; \
      patch -d "{{ source_dir }}" -p1 -i "$p"; \
    done; \
  fi; \
  mkdir -p "{{ stamp_dir }}"; \
  touch "{{ patch_stamp }}"

[private]
unpack: verify
  @if [ -f "{{ unpack_stamp }}" ]; then exit 0; fi; \
  mkdir -p "{{ source_dir }}"; \
  tar -xf "{{ buildroot_file }}" --strip-components=1 -C "{{ source_dir }}"; \
  mkdir -p "{{ stamp_dir }}"; \
  touch "{{ unpack_stamp }}"

[private]
verify: download
  @if [ -f "{{ verify_stamp }}" ]; then exit 0; fi; \
  echo "{{ buildroot_hash }}  {{ buildroot_file }}" | sha256sum --status -c -; \
  mkdir -p "{{ stamp_dir }}"; \
  touch "{{ verify_stamp }}"

[private]
download:
  @if [ -f "{{ download_stamp }}" ]; then exit 0; fi; \
  mkdir -p "{{ download_dir }}/buildroot"; \
  wget -q --show-progress -O "{{ buildroot_file }}" "{{ buildroot_site }}"; \
  mkdir -p "{{ stamp_dir }}"; \
  touch "{{ download_stamp }}"

[private]
dependencies target:
  @if [ ! -f "{{ justfile_directory() }}/configs/{{ target }}_defconfig" ]; then \
    echo "error: missing configs/{{ target }}_defconfig" >&2; \
    exit 1; \
  fi
