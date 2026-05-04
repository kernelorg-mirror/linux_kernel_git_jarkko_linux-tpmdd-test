# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set shell := ["bash", "-euo", "pipefail", "-c"]

build_dir               := env_var_or_default("BUILD", "build")
buildroot_cache         := env_var_or_default("XDG_CACHE_HOME", env_var("HOME") / ".cache") / "buildroot"
buildroot_package_dir   := buildroot_cache / "package"

buildroot_version   := "8e786e873ac759b5804059e8ae750e51c3a006ca"
buildroot_hash      := "14bca416698d21e57f03eecf491339679ac8446839f9b23af172c56acd81acff"
buildroot_tarball   := "buildroot-" + buildroot_version + ".tar.gz"
buildroot_site      := "https://github.com/buildroot/buildroot/archive" / (buildroot_version + ".tar.gz")

download_dir := build_dir / "download"
source_dir   := build_dir / "src" / ("buildroot-" + buildroot_version)
stamp_dir    := build_dir / "stamp"
target_file  := build_dir / "target"
 
download_stamp  := stamp_dir / ".downloaded"
verify_stamp    := stamp_dir / ".verified"
unpack_stamp    := stamp_dir / ".unpacked"
patch_stamp     := stamp_dir / ".patched"
configure_stamp := stamp_dir / ".prepared"

# List available recipes.
default:
    @just --list --unsorted

# Configure build target
configure target: patch
    @if [ -f "{{ configure_stamp }}" ] && [ -f "{{ target_file }}" ] && \
       read -r prev < "{{ target_file }}" && [ "$prev" = "{{ target }}" ]; then exit 0; \
    fi; \
    rm -vf "{{ configure_stamp }}"; \
    rm -vf "{{ target_file }}"; \
    path_abs="{{ absolute_path(build_dir) }}/{{ target }}"; \
    mkdir -p "$path_abs"; \
    make -C "{{source_dir}}" O="$path_abs" \
        BR2_EXTERNAL="{{ justfile_directory() }}" \
        BR2_DL_DIR="{{ buildroot_package_dir }}" \
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
    make BR2_DL_DIR="{{ buildroot_package_dir }}" \
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
    patch -p1 -d "{{ source_dir }}" < "{{ justfile_directory() }}/buildroot.patch"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ patch_stamp }}"

[private]
unpack: verify
    @if [ -f "{{ unpack_stamp }}" ]; then exit 0; fi; \
    mkdir -p "{{ source_dir }}"; \
    tar -xf "{{ download_dir }}/{{ buildroot_tarball }}" --strip-components=1 -C "{{ source_dir }}"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ unpack_stamp }}"

[private]
verify: download
    @if [ -f "{{ verify_stamp }}" ]; then exit 0; fi; \
    echo "{{ buildroot_hash }}  {{ download_dir }}/{{ buildroot_tarball }}" | sha256sum --status -c -; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ verify_stamp }}"

[private]
download:
    @if [ -f "{{ download_stamp }}" ]; then exit 0; fi; \
    mkdir -p "{{ download_dir }}"; \
    wget -q --show-progress -O "{{ download_dir }}/{{ buildroot_tarball }}" "{{ buildroot_site }}"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ download_stamp }}"
