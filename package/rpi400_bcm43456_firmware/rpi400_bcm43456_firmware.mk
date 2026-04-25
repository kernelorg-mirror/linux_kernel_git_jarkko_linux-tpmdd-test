################################################################################
#
# rpi400_bcm43456_firmware
#
################################################################################

RPI400_BCM43456_FIRMWARE_VERSION = 6596d332eaadd63e2413e3937715a084f61c39e2
RPI400_BCM43456_FIRMWARE_SITE = $(call github,LibreELEC,brcmfmac_sdio-firmware-rpi,$(RPI400_BCM43456_FIRMWARE_VERSION))
RPI400_BCM43456_FIRMWARE_LICENSE = PROPRIETARY
RPI400_BCM43456_FIRMWARE_LICENSE_FILES = LICENSE

define RPI400_BCM43456_FIRMWARE_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/lib/firmware/brcm
	cp --remove-destination --no-dereference $(@D)/firmware/brcm/brcmfmac43456-sdio.bin $(TARGET_DIR)/lib/firmware/brcm
	cp --remove-destination --no-dereference $(@D)/firmware/brcm/brcmfmac43456-sdio.clm_blob $(TARGET_DIR)/lib/firmware/brcm
	cp --remove-destination --no-dereference $(@D)/firmware/brcm/brcmfmac43456-sdio.txt $(TARGET_DIR)/lib/firmware/brcm
	chmod 644 \
		$(TARGET_DIR)/lib/firmware/brcm/brcmfmac43456-sdio.bin \
		$(TARGET_DIR)/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob \
		$(TARGET_DIR)/lib/firmware/brcm/brcmfmac43456-sdio.txt
	ln -sf brcmfmac43456-sdio.bin $(TARGET_DIR)/lib/firmware/brcm/brcmfmac43456-sdio.raspberrypi,400.bin
	ln -sf brcmfmac43456-sdio.clm_blob $(TARGET_DIR)/lib/firmware/brcm/brcmfmac43456-sdio.raspberrypi,400.clm_blob
	ln -sf brcmfmac43456-sdio.txt $(TARGET_DIR)/lib/firmware/brcm/brcmfmac43456-sdio.raspberrypi,400.txt
endef

$(eval $(generic-package))
