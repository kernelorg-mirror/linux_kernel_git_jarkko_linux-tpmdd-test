# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

# Make is the single build language: this orchestrator and Buildroot. Run
# `make` for targets, or `make list` for available defconfigs.

# Build system
SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

REQUIRED_HOST_TOOLS		:= curl flock sha256sum virt-install virsh wget xz

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
BUILDROOT_TARBALL		:= $(BUILDROOT_DL_DIR)/buildroot-$(BUILDROOT_VERSION).tar.xz
BUILDROOT_PATCH			:= $(CURDIR)/buildroot-$(BUILDROOT_VERSION).patch
BUILDROOT_SRC_DIR		:= $(BOARD_DIR)/src/buildroot-$(BUILDROOT_VERSION)

# SDK
# Relocated toolchains stay in the cache. Unpack and O= trees are
# scratch under OUTPUT_DIR so `make clean` removes them.
SDK_DIR				:= $(CACHE_DIR)/sdk
SDK_CACHE_DIR			:= $(SDK_DIR)/$(BUILDROOT_VERSION)
SDK_ROOT			= $(SDK_CACHE_DIR)/$(1)/$(1)-tpmdd-linux-gnu_sdk-buildroot
SDK_BUILD_DIR			:= $(abspath $(OUTPUT_DIR))/sdk/$(BUILDROOT_VERSION)
SDK_SRC_DIR			:= $(SDK_BUILD_DIR)/src/buildroot-$(BUILDROOT_VERSION)
SDK_ARCHS			:= $(patsubst sdk/%_defconfig,%,$(wildcard sdk/*_defconfig))
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
PATCH_STAMP			:= $(STAMP_DIR)/$(BUILDROOT_VERSION)/patch
SDK_UNPACK_STAMP		:= $(SDK_BUILD_DIR)/.stamp/unpack
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

define download
$(1): $(1).$(3)
	@mkdir -p "$(dir $(1))"
	if [ ! -f "$(1)" ] || ! echo "$(3)  $(1)" | sha256sum --status -c -; then
		curl -fL --retry 3 --connect-timeout 10 --progress-bar -o "$(1).partial" "$(2)"
		echo "$(3)  $(1).partial" | sha256sum --status -c -
		mv "$(1).partial" "$(1)"
	fi
	touch "$(1)"

$(1).$(3):
	@mkdir -p "$(dir $(1))"
	touch "$$@"
endef

.PHONY: default help list download dependencies sdk clean-sdk configure build install-virtd burn ssh clean lint

help: ## Show this help
	@awk -F ':[^#]*## ?' '/^[a-z_-]+:[^#]*##/{printf "  make %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

default: help

$(eval $(call download,$(BUILDROOT_TARBALL),$(BUILDROOT_URL),$(BUILDROOT_HASH)))

ifneq ($(filter configure build install-virtd burn ssh,$(MAKECMDGOALS)),)
  ifndef BOARD
    $(error BOARD is required, e.g.: make build BOARD=tpmdd_amd64)
  endif
endif

list: ## List available defconfigs
	@cd configs && ls *_defconfig | sed 's/_defconfig//'

download: $(BUILDROOT_TARBALL) ## Prime the download cache

$(SDK_UNPACK_STAMP): $(BUILDROOT_TARBALL)
	@mkdir -p "$(dir $@)"
	exec 9>"$(dir $@)/unpack.lock"
	flock 9
	if [ -f "$@" ]; then exit 0; fi
	echo "$(BUILDROOT_HASH)  $(BUILDROOT_TARBALL)" | sha256sum --status -c -
	rm -rf "$(SDK_SRC_DIR)"
	mkdir -p "$(SDK_SRC_DIR)"
	tar -xf "$(BUILDROOT_TARBALL)" --strip-components=1 -C "$(SDK_SRC_DIR)"
	touch "$@"

define sdk_rules
.PHONY: sdk-$(1)

sdk-$(1): $(SDK_CACHE_DIR)/.stamp/$(1)/install

$(SDK_BUILD_DIR)/.stamp/$(1)/build: $(SDK_UNPACK_STAMP) $(CURDIR)/sdk/$(1)_defconfig
	mkdir -p "$(SDK_BUILD_DIR)/build/$(1)" "$(SDK_BUILD_DIR)/.stamp/$(1)"
	$(MAKE) -C "$(SDK_SRC_DIR)" O="$(SDK_BUILD_DIR)/build/$(1)" \
		BR2_DL_DIR="$(BUILDROOT_DL_DIR)" BR2_CCACHE_DIR="$(CCACHE_DIR)" \
		SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" \
		defconfig DEFCONFIG="$(CURDIR)/sdk/$(1)_defconfig"
	$(MAKE) -C "$(SDK_SRC_DIR)" O="$(SDK_BUILD_DIR)/build/$(1)" \
		BR2_DL_DIR="$(BUILDROOT_DL_DIR)" BR2_CCACHE_DIR="$(CCACHE_DIR)" \
		SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" \
		sdk
	touch "$(SDK_BUILD_DIR)/.stamp/$(1)/build"

# Install stamp lives in the cache and depends only on the defconfig, so a
# populated toolchain is a hit after wiping OUTPUT_DIR.
$(SDK_CACHE_DIR)/.stamp/$(1)/install: $(CURDIR)/sdk/$(1)_defconfig
	sdk_root="$(call SDK_ROOT,$(1))"
	if [ -x "$$$$sdk_root/relocate-sdk.sh" ] && [ ! "$(CURDIR)/sdk/$(1)_defconfig" -nt "$$$$sdk_root/relocate-sdk.sh" ]; then
		mkdir -p "$(SDK_CACHE_DIR)/.stamp/$(1)"
		touch "$(SDK_CACHE_DIR)/.stamp/$(1)/install"
		exit 0
	fi
	$(MAKE) "$(SDK_BUILD_DIR)/.stamp/$(1)/build"
	tarball="$$$$(echo "$(SDK_BUILD_DIR)/build/$(1)/images/"*_sdk-buildroot.tar.gz)"
	test -f "$$$$tarball" || { \
		echo "error: no SDK tarball in $(SDK_BUILD_DIR)/build/$(1)/images" >&2; \
		exit 1; \
	}
	topdir="$$$${tarball##*/}"; topdir="$$$${topdir%.tar.gz}"
	rm -rf "$(SDK_CACHE_DIR)/$(1)"
	mkdir -p "$(SDK_CACHE_DIR)/$(1)"
	tar -xzf "$$$$tarball" -C "$(SDK_CACHE_DIR)/$(1)"
	test -x "$(SDK_CACHE_DIR)/$(1)/$$$$topdir/relocate-sdk.sh"
	"$(SDK_CACHE_DIR)/$(1)/$$$$topdir/relocate-sdk.sh"
	mkdir -p "$(SDK_CACHE_DIR)/.stamp/$(1)"
	touch "$(SDK_CACHE_DIR)/.stamp/$(1)/install"
endef
$(foreach arch,$(SDK_ARCHS),$(eval $(call sdk_rules,$(arch))))

sdk: dependencies $(addprefix sdk-,$(SDK_ARCHS)) ## Build and cache SDK toolchains

dependencies: ## Check required host tools
	@missing=()
	for tool in $(REQUIRED_HOST_TOOLS); do
		command -v "$$tool" >/dev/null 2>&1 || missing+=("$$tool")
	done
	if [ "$${#missing[@]}" -ne 0 ]; then
		echo "error: missing required host tools: $${missing[*]}" >&2
		exit 1
	fi

$(PATCH_STAMP): $(BUILDROOT_TARBALL) $(BUILDROOT_PATCH)
	@echo "$(BUILDROOT_HASH)  $(BUILDROOT_TARBALL)" | sha256sum --status -c -
	src_dir="$(BUILDROOT_SRC_DIR)"
	rm -rf "$$src_dir"
	mkdir -p "$$src_dir"
	tar -xf "$(BUILDROOT_TARBALL)" --strip-components=1 -C "$$src_dir"
	patch -d "$$src_dir" -p1 -i "$(BUILDROOT_PATCH)"
	mkdir -p "$(dir $@)"
	touch "$@"

configure: dependencies $(SDK_INSTALL_STAMP) $(PATCH_STAMP) ## Run <BOARD>_defconfig
	$(call buildroot,$(BOARD)_defconfig)

build: configure ## Build <BOARD>
	$(call buildroot,BR2_CCACHE=y)

install-virtd: ## Define qemu:///session domain tpmdd-<hash> for <BOARD>
	$(call require_artifact,$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT))
	exec "$(CURDIR)/scripts/install-virtd.sh" \
		"$(BOARD_DIR)/images/$(BOARD).$(IMAGE_EXT)" "$(SDK_ARCH)"

ssh: ## Open an SSH session to <BOARD>
	$(call require_artifact,$(BOARD_DIR)/images/ssh_config)
	exec ssh -F "$(BOARD_DIR)/images/ssh_config" tpmdd.local

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

clean: ## Remove build artifacts
	rm -rf "$(abspath $(OUTPUT_DIR))" "$(SDK_CACHE_DIR)/src" "$(SDK_CACHE_DIR)/build"

clean-sdk: ## Remove cached SDK toolchains
	rm -rf "$(SDK_DIR)"

lint: ## Run shellcheck
	mapfile -t sh_files < <(git ls-files '*.sh')
	if [ "$${#sh_files[@]}" -gt 0 ]; then
		shellcheck -x "$${sh_files[@]}"
	fi
