# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

################################################################################
#
# tpm2sh
#
################################################################################

TPM2SH_VERSION = 0.16.19
TPM2SH_SITE = https://git.kernel.org/pub/scm/linux/kernel/git/jarkko/tpm2sh.git
TPM2SH_SITE_METHOD = git
TPM2SH_LICENSE = GPL-2.0+
TPM2SH_LICENSE_FILES = LICENSE

$(eval $(cargo-package))
