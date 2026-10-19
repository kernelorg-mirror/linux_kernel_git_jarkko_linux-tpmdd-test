# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

# Make is the single build language: this orchestrator and Buildroot. Run
# `make` for targets, or `make list` for available defconfigs.

# Build system
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Versions
TPMDD_VERSION			?= 2026.08
SOURCE_DATE_EPOCH		?= 1735689600

# Directories
OUTPUT_DIR			?= build
OUTPUT_DIR_ABS			:= $(abspath $(OUTPUT_DIR))
BOARD_DIR			:= $(abspath $(OUTPUT_DIR)/$(BOARD))
CACHE_DIR			:= $(HOME)/.cache/tpmdd
DOWNLOAD_DIR			:= $(CACHE_DIR)/download
CCACHE_DIR			:= $(CACHE_DIR)/ccache
STAMP_DIR			:= $(BOARD_DIR)/stamp

# Buildroot
BUILDROOT_VERSION		?= 2026.08-rc1
BUILDROOT_HASH			?= fbb78d7e07ca91cc4def0a0730a332e5bcf2234b59f3b0c151104e2dc79ff6fe
BUILDROOT_URL			?= https://buildroot.org/downloads/buildroot-$(BUILDROOT_VERSION).tar.xz
BUILDROOT_DL_DIR		:= $(DOWNLOAD_DIR)/buildroot
BUILDROOT_TARBALL		:= $(BUILDROOT_DL_DIR)/source/$(BUILDROOT_HASH)/buildroot-$(BUILDROOT_VERSION).tar.xz
BUILDROOT_PATCH			:= $(CURDIR)/buildroot.patch
BUILDROOT_PATCH_KEY		:= $(shell sha256sum $(BUILDROOT_PATCH) | cut -d' ' -f1)
BUILDROOT_SRC_DIR		:= $(BOARD_DIR)/src/$(BUILDROOT_HASH)/buildroot-$(BUILDROOT_VERSION)
BUILDROOT_PATCH_LOCK		:= $(OUTPUT_DIR_ABS)/.locks/$(BOARD).patch
BUILDROOT_PATCH_STAMP		:= $(STAMP_DIR)/$(BUILDROOT_VERSION)/$(BUILDROOT_HASH)/$(BUILDROOT_PATCH_KEY)/patch

# SDK
# Relocated toolchains stay in the cache. Unpack and O= trees are
# scratch under OUTPUT_DIR so `make clean` removes them.
SDK_CONFIG_HASH			:= $(shell sha256sum $(sort $(wildcard sdk/*_defconfig)) | sha256sum | cut -d' ' -f1)
ifneq ($(.SHELLSTATUS),0)
$(error failed to hash SDK configurations)
endif
SDK_STAMP_KEY			:= $(shell printf '%s\n' '$(BUILDROOT_VERSION)' '$(BUILDROOT_HASH)' '$(SOURCE_DATE_EPOCH)' '$(SDK_CONFIG_HASH)' | sha256sum | cut -d' ' -f1)
ifneq ($(.SHELLSTATUS),0)
$(error failed to hash SDK inputs)
endif
SDK_DIR				:= $(CACHE_DIR)/sdk
SDK_CACHE_DIR			:= $(SDK_DIR)/$(BUILDROOT_VERSION)/$(SDK_STAMP_KEY)
SDK_LOCK			:= $(CACHE_DIR)/.locks/sdk/$(SDK_STAMP_KEY)
SDK_ROOT			= $(SDK_CACHE_DIR)/$(1)/$(1)-tpmdd-linux-gnu_sdk-buildroot
SDK_BUILD_DIR			:= $(OUTPUT_DIR_ABS)/sdk/$(BUILDROOT_VERSION)/$(SDK_STAMP_KEY)
SDK_ARCHS			:= $(patsubst sdk/%_defconfig,%,$(wildcard sdk/*_defconfig))
BOARDS				:= $(patsubst configs/%_defconfig,%,$(wildcard configs/*_defconfig))
ifdef BOARD
ifeq ($(wildcard configs/$(BOARD)_defconfig),)
$(error unknown BOARD=$(BOARD); see `make list`)
endif
SDK_ARCH := $(strip $(if $(filter BR2_x86_64=y,$(file < configs/$(BOARD)_defconfig)),x86_64,\
	$(if $(filter BR2_aarch64=y,$(file < configs/$(BOARD)_defconfig)),aarch64)))
ifeq ($(SDK_ARCH),)
$(error configs/$(BOARD)_defconfig must select BR2_x86_64 or BR2_aarch64)
endif
else
SDK_ARCH :=
endif

SDK_INSTALL_DIR			:= $(call SDK_ROOT,$(SDK_ARCH))
IMAGE_EXT			:= $(if $(filter tpmdd_arm64,$(BOARD)),img,iso)

# Stamps
SDK_INSTALL_STAMP		:= $(SDK_CACHE_DIR)/.stamp/$(SDK_ARCH)/install

# Buildroot invocation helper.
# BR2_REPRODUCIBLE lives in the defconfigs; it is a Kconfig bool, not
# option env=, so a make-line override would not reach .config.
define buildroot
  $(MAKE) -C "$(BUILDROOT_SRC_DIR)" O="$(BOARD_DIR)" \
    BR2_EXTERNAL="$(CURDIR)" \
    BR2_CCACHE_DIR="$(CCACHE_DIR)" BR2_DL_DIR="$(BUILDROOT_DL_DIR)" \
    SDK_INSTALL_DIR="$(SDK_INSTALL_DIR)" \
    TPMDD_VERSION="$(TPMDD_VERSION)" SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" \
    $(1)
endef

# Require a build artifact, erroring with a build hint if missing.
define require_artifact
  @if [ ! -f "$(1)" ]; then
    echo "error: $(1) not found; run: make build BOARD=$(BOARD)" >&2
    exit 2
  fi
endef

.PHONY: default help list download sdk clean-sdk configure build burn ssh clean lint

help: ## Show this help
	@awk -F ':[^#]*## ?' '/^[a-z_-]+:[^#]*##/{printf "  make %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

default: help

$(BUILDROOT_TARBALL):
	./scripts/download.sh "$(BUILDROOT_URL)" "$(BUILDROOT_HASH)" "$@"

ifneq ($(filter configure build burn ssh,$(MAKECMDGOALS)),)
  ifndef BOARD
    $(error BOARD is required, e.g.: make build BOARD=tpmdd_amd64)
  endif
endif

list: ## List available defconfigs
	@printf '%s\n' $(BOARDS)

download: $(BUILDROOT_TARBALL) ## Prime the download cache

.PRECIOUS: $(SDK_CACHE_DIR)/.stamp/%/install

sdk-%: $(SDK_CACHE_DIR)/.stamp/%/install ;

sdk: $(addprefix sdk-,$(SDK_ARCHS)) ## Build and cache SDK toolchains
	rm -rf "$(SDK_BUILD_DIR)"

$(SDK_CACHE_DIR)/.stamp/%/install: $(BUILDROOT_TARBALL) sdk/%_defconfig
	./scripts/build-sdk.sh "$*" "sdk/$*_defconfig" "$(BUILDROOT_TARBALL)" "$(BUILDROOT_HASH)" \
		"$(SDK_BUILD_DIR)" "$(SDK_CACHE_DIR)" "$(SDK_LOCK)" "$(BUILDROOT_DL_DIR)" "$(SOURCE_DATE_EPOCH)"

$(BUILDROOT_PATCH_STAMP): $(BUILDROOT_TARBALL) $(BUILDROOT_PATCH)
	./scripts/setup-buildroot.sh "$(BUILDROOT_PATCH_LOCK)" "$(BUILDROOT_TARBALL)" "$(BUILDROOT_HASH)" \
		"$(BOARD_DIR)" "$(BUILDROOT_SRC_DIR)" "$@" "$(BUILDROOT_PATCH)"

configure: $(SDK_INSTALL_STAMP) $(BUILDROOT_PATCH_STAMP) ## Run <BOARD>_defconfig
	$(call buildroot,$(BOARD)_defconfig)

build: configure ## Build <BOARD>
	$(call buildroot,BR2_CCACHE=y)

ssh: ## Open an SSH session to <BOARD>
	$(call require_artifact,$(BOARD_DIR)/images/ssh_config)
	exec ssh -F "$(BOARD_DIR)/images/ssh_config" tpmdd.local

burn: ## Write existing image to DEVICE (does not build)
	./scripts/burn.sh "$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT)" "$(DEVICE)" "$(BOARD)"

clean: ## Remove build artifacts
	rm -rf "$(abspath $(OUTPUT_DIR))"

clean-sdk: ## Remove cached SDK toolchains
	rm -rf "$(SDK_DIR)"

lint: ## Run shellcheck
	./scripts/lint.sh
