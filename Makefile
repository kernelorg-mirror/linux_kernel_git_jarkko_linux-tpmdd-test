.PHONY: all prepare clean help
.DEFAULT_GOAL := help

# Parameters
BUILD ?= build
DEFCONFIG ?= pc_x86_64_defconfig

DEFCONFIG := $(CURDIR)/configs/$(DEFCONFIG)

BUILDROOT_VERSION	:= 2026.02-rc1
BUILDROOT_SHA256	:= fba6f0aacfe8a38d5cd164286b3a1ac79371f8bf84772b0a412dea627dba414e
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

MAKEOPTS := -C $(BUILD_SOURCE_DIR) O=$(abspath $(BUILD_BINARY_DIR)) BR2_EXTERNAL=$(abspath $(CURDIR)) V=0

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
	@echo "  DEFCONFIG            defconfig [default: pc_x86_64_defconfig]"

prepare: $(CONFIG_STAMP) ## Download, unpack and configure BuildRoot.

$(BUILD_IMAGE_DIR)/disk.img: $(CONFIG_STAMP)
	$(MAKE) $(MAKEOPTS)

clean: ## Delete build artifacts.
	@if [ -z "$(BUILD)" ] || [ "$(BUILD)" = "/" ] || [ "$(shell echo $(BUILD) | cut -c1-1)" = "/" ]; then \
		echo "ERROR: BUILD variable is unsafe ('$(BUILD)'). Aborting clean."; \
		exit 1; \
	fi
	rm -rf $(BUILD)

$(CONFIG_STAMP): $(PATCH_STAMP)
	$(MAKE) $(MAKEOPTS) BR2_DEFCONFIG=$(DEFCONFIG) defconfig
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
