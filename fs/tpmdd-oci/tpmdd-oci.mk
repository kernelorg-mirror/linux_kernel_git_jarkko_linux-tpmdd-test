################################################################################
#
# tpmdd-oci
#
################################################################################

ROOTFS_TPMDD_OCI_DEPENDENCIES = host-sloci-image
ROOTFS_TPMDD_OCI_IMAGE_NAME = image.tar

ifeq ($(BR2_x86_64),y)
ROOTFS_TPMDD_OCI_ARCH = amd64
else ifeq ($(BR2_aarch64),y)
ROOTFS_TPMDD_OCI_ARCH = arm64
endif

ifeq ($(BR2_TARGET_ROOTFS_TPMDD_OCI),y)
ifeq ($(ROOTFS_TPMDD_OCI_ARCH),)
$(error tpmdd-oci requires BR2_x86_64 or BR2_aarch64)
endif
endif

define ROOTFS_TPMDD_OCI_CMD
	rm -rf $(ROOTFS_TPMDD_OCI_DIR)/oci
	SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)" $(HOST_DIR)/bin/sloci-image \
		--arch $(ROOTFS_TPMDD_OCI_ARCH) \
		--author tpmdd-oci \
		--cmd /sbin/init \
		--label containers.bootc=1 \
		--label ostree.bootable=1 \
		--label .title=tpmdd \
		--label .version=$(TPMDD_VERSION) \
		--label .licenses=GPL-2.0-or-later \
		--label .source=https://git.kernel.org/pub/scm/linux/kernel/git/jarkko/linux-tpmdd.git \
		--tar \
		--output $@ \
		$(TARGET_DIR) $(ROOTFS_TPMDD_OCI_DIR)/oci:latest
endef

$(eval $(rootfs))
