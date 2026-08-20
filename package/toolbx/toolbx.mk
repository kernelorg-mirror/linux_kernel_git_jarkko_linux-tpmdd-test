################################################################################
#
# toolbx
#
################################################################################

TOOLBX_VERSION = 0.3
TOOLBX_SOURCE = toolbox-$(TOOLBX_VERSION)-vendored.tar.xz
TOOLBX_SITE = https://github.com/containers/toolbox/releases/download/$(TOOLBX_VERSION)
TOOLBX_LICENSE = Apache-2.0
TOOLBX_LICENSE_FILES = COPYING
TOOLBX_DEPENDENCIES = shadow

TOOLBX_GOMOD = github.com/containers/toolbox
TOOLBX_BIN_NAME = toolbox

# Upstream release archive is already vendored; keep it as xz.
TOOLBX_DOWNLOAD_POST_PROCESS =

# ELF interpreter path on the target. At runtime inside a toolbox container
# the host root is visible under /run/host, so the interpreter and rpath are
# prefixed accordingly.
ifeq ($(BR2_x86_64),y)
TOOLBX_DYNAMIC_LINKER = /lib/ld-linux-x86-64.so.2
else ifeq ($(BR2_aarch64),y)
TOOLBX_DYNAMIC_LINKER = /lib/ld-linux-aarch64.so.1
endif

TOOLBX_GO_ENV = \
	CGO_ENABLED=1 \
	CGO_CFLAGS="$(TARGET_CFLAGS)" \
	CGO_LDFLAGS="$(TARGET_LDFLAGS) $(TOOLBX_EXTLDFLAGS)"

TOOLBX_EXTLDFLAGS = \
	-Wl,--export-dynamic,--unresolved-symbols,ignore-in-object-files,-z,lazy

TOOLBX_BUILD_OPTS += -mod=vendor

define TOOLBX_BUILD_CMDS
	cd $(@D)/src && \
	$(HOST_GO_TARGET_ENV) \
	$(TOOLBX_GO_ENV) \
	$(GO_BIN) build -v $(TOOLBX_BUILD_OPTS) \
		-o $(@D)/bin/toolbox \
		.
endef

define TOOLBX_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bin/toolbox \
		$(TARGET_DIR)/usr/bin/toolbox
	$(INSTALL) -D -m 0644 $(@D)/data/config/toolbox.conf \
		$(TARGET_DIR)/etc/containers/toolbox.conf
	$(INSTALL) -D -m 0644 $(@D)/data/tmpfiles.d/toolbox.conf \
		$(TARGET_DIR)/usr/lib/tmpfiles.d/toolbox.conf
	$(INSTALL) -D -m 0644 $(@D)/profile.d/toolbox.sh \
		$(TARGET_DIR)/etc/profile.d/toolbox.sh
endef

$(eval $(golang-package))
