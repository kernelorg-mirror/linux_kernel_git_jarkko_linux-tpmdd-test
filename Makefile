# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

.PHONY: all prepare burn clean help
.DEFAULT_GOAL := help

# Parameters
BUILD ?= build
BR2_DEFCONFIG ?= configs/pc_x86_64_efi_defconfig

BUILDROOT_VERSION	:= 2026.02
BUILDROOT_SHA256	:= a98351d46dd3ed3201e426eda3e01ff938ccc4571ec7e04eb57939c85c4e8cb5
BUILDROOT_TARBALL	:= buildroot-$(BUILDROOT_VERSION).tar.gz
BUILDROOT_URL		:= https://buildroot.org/downloads/$(BUILDROOT_TARBALL)

BUILD_BASE_DIR		:= $(BUILD)/buildroot
BUILD_BINARY_DIR	:= $(BUILD_BASE_DIR)/build
BUILD_DOWNLOAD_DIR	:= $(BUILD_BASE_DIR)/download
BUILD_IMAGE_DIR		:= $(BUILD_BASE_DIR)/build/images
BUILD_SOURCE_DIR	:= $(BUILD_BASE_DIR)/src/buildroot-$(BUILDROOT_VERSION)
BUILD_STAMP_DIR		:= $(BUILD_BASE_DIR)/stamp

VERIFY_STAMP		:= $(BUILD_STAMP_DIR)/.verified
UNPACK_STAMP		:= $(BUILD_STAMP_DIR)/.unpacked
PATCH_STAMP		:= $(BUILD_STAMP_DIR)/.patched
CONFIG_STAMP		:= $(BUILD_STAMP_DIR)/.configured

DOWNLOAD_STAMP		:= $(BUILD_STAMP_DIR)/.downloaded

MAKEOPTS := -C $(BUILD_SOURCE_DIR) O=$(abspath $(BUILD_BINARY_DIR)) BR2_EXTERNAL=$(abspath $(CURDIR)) BR2_DEFCONFIG=$(abspath $(BR2_DEFCONFIG)) V=0

all: $(BUILD_IMAGE_DIR)/disk.img ## Build the disk image.

help: ## Show this help message.
	@echo "Usage: make <target> [variable=value]"
	@echo ""
	@echo "Targets:"
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  BUILD                build directory [default: build]"
	@echo "  DEVICE:              device used for burning disk image"
	@echo "  BR2_DEFCONFIG        defconfig [default: configs/pc_x86_64_efi_defconfig]"

prepare: $(CONFIG_STAMP) ## Download, unpack and configure BuildRoot.

burn: $(BUILD_IMAGE_DIR)/disk.img
	@if [ -z "$(DEVICE)" ]; then \
		echo "ERROR: DEVICE variable is not defined. Aborting burn."; \
		exit 1; \
	fi
	@if [ ! -b "$(DEVICE)" ]; then \
		echo "ERROR: DEVICE is not a block device. Aborting burn."; \
		exit 1; \
	fi
	sudo dd if=$(BUILD_IMAGE_DIR)/disk.img of=$(DEVICE) bs=1M status=progress oflag=sync

$(BUILD_IMAGE_DIR)/disk.img: $(CONFIG_STAMP)
	$(MAKE) $(MAKEOPTS)

clean: ## Delete build artifacts.
	@if [ -z "$(BUILD)" ] || [ "$(BUILD)" = "/" ] || [ "$(shell echo $(BUILD) | cut -c1-1)" = "/" ]; then \
		echo "ERROR: BUILD variable is unsafe ('$(BUILD)'). Aborting clean."; \
		exit 1; \
	fi
	rm -rf $(BUILD)

$(CONFIG_STAMP): $(PATCH_STAMP)
	$(MAKE) $(MAKEOPTS) BR2_DEFCONFIG=$(abspath $(BR2_DEFCONFIG)) defconfig
	@mkdir -p $(BUILD_BINARY_DIR)
	@mkdir -p $(@D)
	@touch $@

$(PATCH_STAMP): $(UNPACK_STAMP)
	@echo "Patching Buildroot"
	@patch -p1 -d $(BUILD_SOURCE_DIR) < $(CURDIR)/buildroot.patch
	@mkdir -p $(@D)
	@touch $@

$(UNPACK_STAMP): $(VERIFY_STAMP)
	@echo "Unpacking Buildroot"
	@mkdir -p $(BUILD_SOURCE_DIR)
	@tar -xf $(BUILD_DOWNLOAD_DIR)/$(BUILDROOT_TARBALL) --strip-components=1 -C $(BUILD_SOURCE_DIR)
	@mkdir -p $(@D)
	@touch $@

$(VERIFY_STAMP): $(DOWNLOAD_STAMP)
	@echo "Verifying Buildroot"
	@echo "$(BUILDROOT_SHA256)  $(BUILD_DOWNLOAD_DIR)/$(BUILDROOT_TARBALL)" | sha256sum --status -c -
	@mkdir -p $(@D)
	@touch $@

$(DOWNLOAD_STAMP):
	@echo "Downloading Buildroot"
	@mkdir -p $(BUILD_DOWNLOAD_DIR)
	@wget -q --show-progress -O $(BUILD_DOWNLOAD_DIR)/$(BUILDROOT_TARBALL) $(BUILDROOT_URL)
	@mkdir -p $(@D)
	@touch $@
