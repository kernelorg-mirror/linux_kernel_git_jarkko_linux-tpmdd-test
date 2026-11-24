# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

# Make is the single build language: this orchestrator and Buildroot. Run
# `make` for targets, or `make list` for available defconfigs.

# Build system
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Versions
TPMDD_VERSION			?= 2026.11
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
BUILDROOT_JOBS			?= 8
BUILDROOT_VERSION		?= 2026.11-rc2
BUILDROOT_HASH			?= bd0db098e09c476a6d11007f5d8485afbade40ce6d290ceb13c3c4874b577cb6
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
BOARDS				:= $(patsubst br2-external/configs/%_defconfig,%,$(wildcard br2-external/configs/*_defconfig))
ifdef BOARD
ifeq ($(wildcard br2-external/configs/$(BOARD)_defconfig),)
$(error unknown BOARD=$(BOARD); see `make list`)
endif
SDK_ARCH := $(strip $(if $(filter BR2_x86_64=y,$(file < br2-external/configs/$(BOARD)_defconfig)),x86_64,\
	$(if $(filter BR2_aarch64=y BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX="aarch64-tpmdd-linux-gnu",$(file < br2-external/configs/$(BOARD)_defconfig)),aarch64)))
ifeq ($(SDK_ARCH),)
$(error br2-external/configs/$(BOARD)_defconfig must select BR2_x86_64 or BR2_aarch64)
endif
TPMDD_ARCH := $(if $(filter x86_64,$(SDK_ARCH)),amd64,arm64)
else
SDK_ARCH :=
TPMDD_ARCH :=
endif

SDK_INSTALL_DIR			:= $(call SDK_ROOT,$(SDK_ARCH))
SDK_INSTALL_STAMP		:= $(SDK_CACHE_DIR)/.stamp/$(SDK_ARCH)/install
IMAGE_EXT			:= $(if $(filter arm64,$(TPMDD_ARCH)),img,iso)

export BOARD BOARD_DIR TPMDD_ARCH TPMDD_VERSION SOURCE_DATE_EPOCH
export BUILDROOT_JOBS BUILDROOT_SRC_DIR BUILDROOT_DL_DIR
export BUILDROOT_TARBALL BUILDROOT_HASH BUILDROOT_PATCH
export BUILDROOT_PATCH_STAMP BUILDROOT_PATCH_LOCK
export SDK_INSTALL_DIR SDK_INSTALL_STAMP CCACHE_DIR

# Require a build artifact, erroring with a build hint if missing.
define require_artifact
  @if [ ! -f "$(1)" ]; then
    echo "error: $(1) not found; run: make build BOARD=$(BOARD)" >&2
    exit 2
  fi
endef

.PHONY: default help list download sdk clean-sdk configure savedefconfig linux-update-defconfig build burn ssh clean lint

help: ## Show this help
	@awk -F ':[^#]*## ?' '/^[a-z_-]+:[^#]*##/{printf "  make %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

default: help

$(BUILDROOT_TARBALL):
	./scripts/download.sh "$(BUILDROOT_URL)" "$(BUILDROOT_HASH)" "$@"

ifneq ($(filter configure savedefconfig linux-update-defconfig build burn ssh,$(MAKECMDGOALS)),)
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
	./scripts/buildroot-sdk.sh "$*" "sdk/$*_defconfig" "$(BUILDROOT_TARBALL)" "$(BUILDROOT_HASH)" \
		"$(SDK_BUILD_DIR)" "$(SDK_CACHE_DIR)" "$(SDK_LOCK)" "$(BUILDROOT_DL_DIR)" "$(SOURCE_DATE_EPOCH)"

configure: $(BUILDROOT_TARBALL) $(SDK_INSTALL_STAMP) ## Force <BOARD> configuration
	./scripts/buildroot-board.sh configure

savedefconfig: $(BUILDROOT_TARBALL) $(SDK_INSTALL_STAMP) ## Save minimal <BOARD> defconfig
	./scripts/buildroot-board.sh savedefconfig

linux-update-defconfig: $(BUILDROOT_TARBALL) $(SDK_INSTALL_STAMP) ## Save minimal <BOARD> kernel defconfig
	./scripts/buildroot-board.sh linux-update-defconfig

build: $(BUILDROOT_TARBALL) $(SDK_INSTALL_STAMP) ## Incrementally build <BOARD> (FORCE=1 to run again)
	./scripts/buildroot-board.sh build

ssh: ## Open an SSH session to <BOARD>
	$(call require_artifact,$(BOARD_DIR)/images/ssh_config)
	exec ssh -F "$(BOARD_DIR)/images/ssh_config" tpmdd.local

burn: ## Write existing image to DEVICE (does not build)
	$(call require_artifact,$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT))
	./scripts/burn.sh "$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT)" "$(DEVICE)"

clean: ## Remove build artifacts
	rm -rf "$(abspath $(OUTPUT_DIR))"

clean-sdk: ## Remove cached SDK toolchains
	rm -rf "$(SDK_DIR)"

lint: ## Run linters
	./scripts/lint.sh
