################################################################################
#
# tpm2sh
#
################################################################################

TPM2SH_VERSION = 0.15.1
TPM2SH_SITE = https://git.kernel.org/pub/scm/linux/kernel/git/jarkko/tpm2sh.git
TPM2SH_SITE_METHOD = git
TPM2SH_LICENSE = GPL-3.0+
TPM2SH_LICENSE_FILES = LICENSE

$(eval $(cargo-package))
