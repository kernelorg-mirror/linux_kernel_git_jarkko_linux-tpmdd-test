# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set shell := ["bash", "-euo", "pipefail", "-c"]

build         := env_var_or_default("BUILD", "build")

buildroot_version := "2026.02"
buildroot_sha256  := "a98351d46dd3ed3201e426eda3e01ff938ccc4571ec7e04eb57939c85c4e8cb5"
buildroot_tarball := "buildroot-" + buildroot_version + ".tar.gz"
buildroot_url     := "https://buildroot.org/downloads/" + buildroot_tarball

base_dir     := build / "buildroot"
binary_dir   := base_dir / "build"
download_dir := base_dir / "download"
image_dir    := base_dir / "build" / "images"
source_dir   := base_dir / "src" / ("buildroot-" + buildroot_version)
stamp_dir    := base_dir / "stamp"

download_stamp := stamp_dir / ".downloaded"
verify_stamp   := stamp_dir / ".verified"
unpack_stamp   := stamp_dir / ".unpacked"
patch_stamp    := stamp_dir / ".patched"
prepare_stamp  := stamp_dir / ".prepared"

# List available recipes.
default:
    @just --list --unsorted

# Download and configure Buildroot.
prepare defconfig: patch
    @if [ -f "{{ prepare_stamp }}" ]; then exit 0; fi;
    make -C "{{ source_dir }}" \
        O="{{ absolute_path(binary_dir) }}" \
        BR2_EXTERNAL="{{ justfile_directory() }}" \
        BR2_DEFCONFIG="{{ absolute_path(defconfig) }}" \
        V=0 defconfig
    mkdir -p "{{ binary_dir }}"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ prepare_stamp }}"

# Burn the disk image.
burn device: build
    @if [ ! -b "{{ device }}" ]; then \
        echo "ERROR: {{ device }} is not a block device." >&2; \
        exit 1; \
    fi
    sudo dd if="{{ image_dir }}/disk.img" of="{{ device }}" bs=1M status=progress oflag=sync

# Build the disk image.
build:
    @if [ ! -f "{{ prepare_stamp }}" ]; then \
        echo "ERROR: prepare first." >&2; \
        exit 1; \
    fi
    make -C "{{ source_dir }}" \
        O="{{ absolute_path(binary_dir) }}" \
        BR2_EXTERNAL="{{ justfile_directory() }}" \
        V=0

# Delete build artifacts.
clean:
    @case "{{ build }}" in \
        ""|/|/*) echo "ERROR: BUILD is unsafe ('{{ build }}'). Aborting clean." >&2; exit 1 ;; \
    esac
    rm -rf "{{ build }}"

[private]
patch: unpack
    @if [ -f "{{ patch_stamp }}" ]; then exit 0; fi; \
    echo "Patching Buildroot"; \
    patch -p1 -d "{{ source_dir }}" < "{{ justfile_directory() }}/buildroot.patch"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ patch_stamp }}"

[private]
unpack: verify
    @if [ -f "{{ unpack_stamp }}" ]; then exit 0; fi; \
    echo "Unpacking Buildroot"; \
    mkdir -p "{{ source_dir }}"; \
    tar -xf "{{ download_dir }}/{{ buildroot_tarball }}" --strip-components=1 -C "{{ source_dir }}"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ unpack_stamp }}"

[private]
verify: download
    @if [ -f "{{ verify_stamp }}" ]; then exit 0; fi; \
    echo "Verifying Buildroot"; \
    echo "{{ buildroot_sha256 }}  {{ download_dir }}/{{ buildroot_tarball }}" | sha256sum --status -c -; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ verify_stamp }}"

[private]
download:
    @if [ -f "{{ download_stamp }}" ]; then exit 0; fi; \
    echo "Downloading Buildroot"; \
    mkdir -p "{{ download_dir }}"; \
    wget -q --show-progress -O "{{ download_dir }}/{{ buildroot_tarball }}" "{{ buildroot_url }}"; \
    mkdir -p "{{ stamp_dir }}"; \
    touch "{{ download_stamp }}"
