################################################################################
#
# tpm2sh
#
################################################################################

TPM2SH_VERSION = 1.1.1
TPM2SH_SITE = $(call github,jarkkojs,tpm2-library,$(TPM2SH_VERSION))
TPM2SH_SUBDIR = crates/sh
TPM2SH_LICENSE = GPL-3.0-or-later
TPM2SH_LICENSE_FILES = crates/sh/LICENSE
TPM2SH_DEPENDENCIES = host-pkgconf openssl

$(eval $(cargo-package))
