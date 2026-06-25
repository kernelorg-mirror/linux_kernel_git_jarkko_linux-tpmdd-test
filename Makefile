# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

# Build system
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Versions
BUILDROOT_VERSION ?= 2026.05

# URLs and hashes
BUILDROOT_HASH ?= 9d2f3af10fcac763a61ff6e41894a033f9ecf9267ba13dd0912eedcd3be2b22a
BUILDROOT_URL  ?= https://buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz

# Directories
BUILD_DIR    ?= build
BOARD_DIR    := $(abspath $(BUILD_DIR)/$(BOARD))
STAMP_DIR    := $(BOARD_DIR)/stamp
CACHE_DIR    := $(HOME)/.cache/tpmdd/buildroot
DOWNLOAD_DIR := $(CACHE_DIR)/download

# Stamps
VERIFY_STAMP := $(STAMP_DIR)/$(BUILDROOT_VERSION)/verify
UNPACK_STAMP := $(STAMP_DIR)/$(BUILDROOT_VERSION)/unpack
PATCH_STAMP  := $(STAMP_DIR)/$(BUILDROOT_VERSION)/patch

# Artifacts
BUILDROOT_TARBALL := $(DOWNLOAD_DIR)/buildroot-$(BUILDROOT_VERSION).tar.xz

# Buildroot invocation helper
define buildroot
  make -C "$(BOARD_DIR)/src/buildroot-$(BUILDROOT_VERSION)" O="$(BOARD_DIR)" \
    BR2_EXTERNAL="$(CURDIR)" BR2_DL_DIR="$(DOWNLOAD_DIR)" \
    $(1)
endef

ifneq ($(filter-out default help list clean download,$(MAKECMDGOALS)),)
  ifndef BOARD
    $(error BOARD is required, e.g.: make build BOARD=tpmdd_amd64_efi)
  endif
endif
.PHONY: default help list download dependencies configure build burn clean

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

$(UNPACK_STAMP): $(VERIFY_STAMP)
	@path_abs="$(BOARD_DIR)"
	src_dir="$$path_abs/src/buildroot-$(BUILDROOT_VERSION)"
	rm -rf "$$src_dir"
	mkdir -p "$$src_dir"
	tar -xf "$(BUILDROOT_TARBALL)" --strip-components=1 -C "$$src_dir"
	mkdir -p "$(dir $@)"
	touch "$@"

$(PATCH_STAMP): $(UNPACK_STAMP)
	@path_abs="$(BOARD_DIR)"
	src_dir="$$path_abs/src/buildroot-$(BUILDROOT_VERSION)"
	patches_dir="$(CURDIR)/patches/buildroot"
	if [ -d "$$patches_dir" ]; then
		for p in "$$patches_dir"/*.patch; do
			[ -f "$$p" ] || continue
			patch -d "$$src_dir" -p1 -i "$$p"
		done
	fi
	mkdir -p "$(dir $@)"
	touch "$@"

dependencies:
	@if [ ! -f "$(CURDIR)/configs/$(BOARD)_defconfig" ]; then
		echo "error: missing configs/$(BOARD)_defconfig" >&2
		exit 1
	fi

configure: dependencies $(PATCH_STAMP) ## Run <BOARD>_defconfig
	@mkdir -p "$(BOARD_DIR)"
	$(call buildroot,$(BOARD)_defconfig)

build: configure ## Build <BOARD>
	$(call buildroot,)

burn: build ## Write <BOARD> disk image to DEVICE
	@if [ ! -b "$(DEVICE)" ]; then
		echo "error: $(DEVICE) is not a block device" >&2
		exit 1
	fi
	sudo dd if="$(BOARD_DIR)/images/disk.img" \
		of="$(DEVICE)" bs=1M status=progress oflag=sync

clean: ## Remove build artifacts
	rm -rf "$(CURDIR)/$(BUILD_DIR)"
