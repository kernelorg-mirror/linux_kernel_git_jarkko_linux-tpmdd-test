# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

# Build system
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Versions
BUILDROOT_VERSION ?= 2026.05.1

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

# Buildroot invocation helper
define buildroot
  make -C "$(BOARD_DIR)/src/buildroot-$(BUILDROOT_VERSION)" O="$(BOARD_DIR)" \
    BR2_EXTERNAL="$(CURDIR)" BR2_DL_DIR="$(DOWNLOAD_DIR)" \
    BR2_CCACHE_DIR="$(CCACHE_DIR)" \
    $(1)
endef

ifneq ($(filter-out default help list clean download,$(MAKECMDGOALS)),)
  ifndef BOARD
    $(error BOARD is required, e.g.: make build BOARD=tpmdd_amd64)
  endif
endif
.PHONY: default help list download dependencies configure build burn qemu clean

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

configure: dependencies $(PATCH_STAMP) ## Run <BOARD>_defconfig
	@mkdir -p "$(BOARD_DIR)"
	$(call buildroot,$(BOARD)_defconfig)

build: configure ## Build <BOARD>
	$(call buildroot,)

VARIANT ?= iso

burn: build ## Write image to DEVICE (VARIANT=iso|rpi3b|rpi400)
	@if [ -z "$(DEVICE)" ]; then
		echo "error: DEVICE is required, e.g.: make burn BOARD=$(BOARD) DEVICE=/dev/sdX" >&2
		exit 1
	fi
	if [ ! -b "$(DEVICE)" ]; then
		echo "error: $(DEVICE) is not a block device" >&2
		exit 1
	fi
	case "$(VARIANT)" in
	iso) image="$(BOARD_DIR)/images/$(BOARD).iso" ;;
	rpi3b|rpi400)
		if [ "$(BOARD)" != tpmdd_arm64 ]; then
			echo "error: VARIANT=$(VARIANT) requires BOARD=tpmdd_arm64" >&2
			exit 1
		fi
		image="$(BOARD_DIR)/images/$(BOARD)-$(VARIANT).img"
		;;
	*)
		echo "error: unknown VARIANT=$(VARIANT) (iso|rpi3b|rpi400)" >&2
		exit 1
		;;
	esac
	if [ ! -f "$$image" ]; then
		echo "error: $$image not found; run: make build BOARD=$(BOARD)" >&2
		exit 2
	fi
	sudo dd if="$$image" of="$(DEVICE)" bs=1M status=progress oflag=sync

qemu: ## Boot <BOARD> in QEMU
	@if [ ! -f "$(BOARD_DIR)/images/$(BOARD).iso" ]; then
		echo "error: $(BOARD_DIR)/images/$(BOARD).iso not found; run: make build BOARD=$(BOARD)" >&2
		exit 2
	fi
	exec "$(BOARD_DIR)/images/run-qemu.sh"

clean: ## Remove build artifacts
	rm -rf "$(CURDIR)/$(BUILD_DIR)"
