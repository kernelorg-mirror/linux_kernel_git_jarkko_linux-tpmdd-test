# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

# Build system
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Versions
TPMDD_VERSION     ?= 2026.05.1
BUILDROOT_VERSION ?= $(TPMDD_VERSION)
SOURCE_DATE_EPOCH ?= 1735689600

# URLs and hashes
BUILDROOT_HASH ?= ae7f706f087b9ae9083a10a587368dfbf53103c28bf81c2d690198dc4090cb58
BUILDROOT_URL  ?= https://buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz

# Directories
BUILD_DIR    ?= build
BOARD_DIR    := $(abspath $(BUILD_DIR)/$(BOARD))
STAMP_DIR    := $(BOARD_DIR)/stamp
CACHE_DIR    := $(HOME)/.cache/tpmdd
DOWNLOAD_DIR := $(CACHE_DIR)/download
CCACHE_DIR   := $(CACHE_DIR)/ccache

# Stamps
VERIFY_STAMP := $(STAMP_DIR)/$(BUILDROOT_VERSION)/verify
PATCH_STAMP  := $(STAMP_DIR)/$(BUILDROOT_VERSION)/patch

# Artifacts
BUILDROOT_TARBALL := $(DOWNLOAD_DIR)/buildroot-$(BUILDROOT_VERSION).tar.xz
BUILDROOT_PATCH   := $(CURDIR)/buildroot-$(BUILDROOT_VERSION).patch
IMAGE_EXT         := $(if $(filter tpmdd_arm64,$(BOARD)),img,iso)

ifneq ($(BOARD),)
  SDK_DEFCONFIG     := $(CURDIR)/configs/sdk/$(BOARD)_defconfig
  SDK_HOST_ID       := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
  SDK_HOST_LIBC     := $(shell getconf GNU_LIBC_VERSION 2>/dev/null)
  SDK_HOST_CC       := $(shell cc -dumpmachine 2>/dev/null)-$(shell cc -dumpfullversion -dumpversion 2>/dev/null)
  SDK_HOST_BINUTILS := $(shell ld --version 2>/dev/null | head -n 1)
  SDK_PATCHES       := $(shell cd "$(CURDIR)" && find patches -type f -print 2>/dev/null | LC_ALL=C sort)
  SDK_KEY_METADATA  := \
    'buildroot-version=$(BUILDROOT_VERSION)' \
    'buildroot-hash=$(BUILDROOT_HASH)' \
    'source-date-epoch=$(SOURCE_DATE_EPOCH)' \
    'host=$(SDK_HOST_ID)' \
    'host-libc=$(SDK_HOST_LIBC)' \
    'host-cc=$(SDK_HOST_CC)' \
    'host-binutils=$(SDK_HOST_BINUTILS)'

  SDK_KEY           := $(if $(wildcard $(SDK_DEFCONFIG)),$(shell { \
    printf '%s\n' $(SDK_KEY_METADATA); \
    cd "$(CURDIR)"; \
    sha256sum "configs/sdk/$(BOARD)_defconfig" \
      "buildroot-$(BUILDROOT_VERSION).patch" $(SDK_PATCHES); \
  } | sha256sum | cut -d ' ' -f 1),missing-sdk-defconfig)
  SDK_BUILD_DIR := $(abspath $(BUILD_DIR)/sdk/$(BOARD)/$(SDK_KEY))
  SDK_CACHE_DIR := $(CACHE_DIR)/sdk/$(BUILDROOT_VERSION)/$(SDK_HOST_ID)/$(BOARD)/$(SDK_KEY)
  SDK_NAME      := $(BOARD)-$(SDK_KEY)_sdk-buildroot.tar.gz
  SDK_ARCHIVE   := $(SDK_CACHE_DIR)/$(SDK_NAME)
  SDK_CHECKSUM  := $(SDK_ARCHIVE).sha256
  SDK_METADATA  := $(SDK_CACHE_DIR)/metadata
endif

# Buildroot invocation helper
define buildroot
  $(MAKE) -C "$(BOARD_DIR)/src/buildroot-$(BUILDROOT_VERSION)" O="$(BOARD_DIR)" \
    BR2_REPRODUCIBLE=y BR2_EXTERNAL="$(CURDIR)" \
    BR2_CCACHE_DIR="$(CCACHE_DIR)" BR2_DL_DIR="$(DOWNLOAD_DIR)" \
    SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" \
    TPMDD_SDK_ARCHIVE="$(SDK_ARCHIVE)" TPMDD_VERSION="$(TPMDD_VERSION)" \
    $(1)
endef

# Require a build artifact, erroring with a build hint if missing.
define require_artifact
  @if [ ! -f "$(1)" ]; then
    echo "error: $(1) not found; run: make build BOARD=$(BOARD)" >&2
    exit 2
  fi
endef

ifneq ($(filter-out default help list clean download,$(MAKECMDGOALS)),)
  ifndef BOARD
    $(error BOARD is required, e.g.: make build BOARD=tpmdd_amd64)
  endif
endif
.PHONY: default help list download dependencies sdk configure build burn qemu ssh clean

default: help

help: ## Show this help
	@awk -F ':[^#]*## ?' '/^[a-z_-]+:[^#]*##/{printf "  make %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

list: ## List available defconfigs
	@cd configs && ls *_defconfig | sed 's/_defconfig//'

$(BUILDROOT_TARBALL):
	@mkdir -p "$(DOWNLOAD_DIR)"
	wget -q --show-progress -O "$@.partial" "$(BUILDROOT_URL)"
	mv "$@.partial" "$@"

download: $(BUILDROOT_TARBALL) ## Prime the Buildroot download cache

$(VERIFY_STAMP): $(BUILDROOT_TARBALL)
	@echo "$(BUILDROOT_HASH)  $(BUILDROOT_TARBALL)" | sha256sum --status -c -
	mkdir -p "$(dir $@)"
	touch "$@"

$(PATCH_STAMP): $(VERIFY_STAMP) $(BUILDROOT_PATCH)
	@src_dir="$(BOARD_DIR)/src/buildroot-$(BUILDROOT_VERSION)"
	rm -rf "$$src_dir"
	mkdir -p "$$src_dir"
	tar -xf "$(BUILDROOT_TARBALL)" --strip-components=1 -C "$$src_dir"
	patch -d "$$src_dir" -p1 -i "$(BUILDROOT_PATCH)"
	mkdir -p "$(dir $@)"
	touch "$@"

dependencies:
	@if [ ! -f "$(CURDIR)/configs/$(BOARD)_defconfig" ]; then
		echo "error: missing configs/$(BOARD)_defconfig" >&2
		exit 1
	fi

sdk: ## Build or verify the cached <BOARD> SDK
	@BOARD="$(BOARD)" \
	SDK_DEFCONFIG="$(SDK_DEFCONFIG)" \
	SDK_HOST_ID="$(SDK_HOST_ID)" \
	SDK_HOST_LIBC="$(SDK_HOST_LIBC)" \
	SDK_HOST_CC="$(SDK_HOST_CC)" \
	SDK_HOST_BINUTILS="$(SDK_HOST_BINUTILS)" \
	SDK_CACHE_DIR="$(SDK_CACHE_DIR)" \
	SDK_ARCHIVE="$(SDK_ARCHIVE)" \
	SDK_CHECKSUM="$(SDK_CHECKSUM)" \
	SDK_METADATA="$(SDK_METADATA)" \
	SDK_KEY="$(SDK_KEY)" \
	PATCH_STAMP="$(PATCH_STAMP)" \
	SDK_BUILD_DIR="$(SDK_BUILD_DIR)" \
	SDK_NAME="$(SDK_NAME)" \
	BUILDROOT_VERSION="$(BUILDROOT_VERSION)" \
	BUILDROOT_HASH="$(BUILDROOT_HASH)" \
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" \
	BOARD_DIR="$(BOARD_DIR)" \
	CURDIR="$(CURDIR)" \
	CCACHE_DIR="$(CCACHE_DIR)" \
	DOWNLOAD_DIR="$(DOWNLOAD_DIR)" \
	TPMDD_VERSION="$(TPMDD_VERSION)" \
	MAKE="$(MAKE)" \
	scripts/sdk.sh

configure: sdk dependencies ## Run <BOARD>_defconfig with its cached SDK
	$(MAKE) "$(PATCH_STAMP)" BOARD="$(BOARD)"
	@mkdir -p "$(BOARD_DIR)"
	$(call buildroot,$(BOARD)_defconfig)

build: configure ## Build <BOARD>
	$(call buildroot,)

burn: build ## Write image to DEVICE
	@if [ -z "$(DEVICE)" ]; then
		echo "error: DEVICE is required, e.g.: make burn BOARD=$(BOARD) DEVICE=/dev/sdX" >&2
		exit 1
	fi
	if [ ! -b "$(DEVICE)" ]; then
		echo "error: $(DEVICE) is not a block device" >&2
		exit 1
	fi
	image="$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT)"
	if [ ! -f "$$image" ]; then
		echo "error: $$image not found; run: make build BOARD=$(BOARD)" >&2
		exit 2
	fi
	sudo dd if="$$image" of="$(DEVICE)" bs=1M status=progress oflag=sync

qemu: ## Boot <BOARD> in QEMU
	$(call require_artifact,$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT))
	exec "$(BOARD_DIR)/images/qemu-exec.sh"

ssh: ## Open an SSH session to <BOARD>
	$(call require_artifact,$(BOARD_DIR)/images/ssh_config)
	exec ssh -F "$(BOARD_DIR)/images/ssh_config" tpmdd.local

clean: ## Remove build artifacts
	rm -rf "$(CURDIR)/$(BUILD_DIR)"
