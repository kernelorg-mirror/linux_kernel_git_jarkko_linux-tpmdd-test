################################################################################
#
# rpi-uefi
#
################################################################################

RPI_UEFI_VERSION = 1.52
RPI_UEFI_SITE = https://github.com/pftf/RPi3/releases/download/v$(RPI_UEFI_VERSION)
RPI_UEFI_SOURCE = RPi3_UEFI_Firmware_v$(RPI_UEFI_VERSION).zip
RPI_UEFI_EXTRA_DOWNLOADS = \
	https://github.com/pftf/RPi4/releases/download/v$(RPI_UEFI_VERSION)/RPi4_UEFI_Firmware_v$(RPI_UEFI_VERSION).zip
RPI_UEFI_LICENSE = BSD-2-Clause-Patent
RPI_UEFI_LICENSE_FILES = rpi3/Readme.md
RPI_UEFI_INSTALL_TARGET = NO
RPI_UEFI_INSTALL_IMAGES = YES

define RPI_UEFI_EXTRACT_CMDS
	mkdir -p $(@D)/rpi3 $(@D)/rpi4
	$(UNZIP) -d $(@D)/rpi3 $(RPI_UEFI_DL_DIR)/$(RPI_UEFI_SOURCE)
	$(UNZIP) -d $(@D)/rpi4 \
		$(RPI_UEFI_DL_DIR)/RPi4_UEFI_Firmware_v$(RPI_UEFI_VERSION).zip
endef

define RPI_UEFI_INSTALL_IMAGES_CMDS
	mkdir -p $(BINARIES_DIR)/rpi-uefi/rpi3 $(BINARIES_DIR)/rpi-uefi/rpi4
	cp -a $(@D)/rpi3/. $(BINARIES_DIR)/rpi-uefi/rpi3/
	cp -a $(@D)/rpi4/. $(BINARIES_DIR)/rpi-uefi/rpi4/
endef

$(eval $(generic-package))
