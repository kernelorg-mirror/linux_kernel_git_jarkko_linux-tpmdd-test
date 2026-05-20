# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

setenv bootargs root=PARTUUID=PARTUUID_TMP rootfstype=ext4 rootwait rootdelay=5 sdhci.debug_quirks2=0x4 earlycon=uart8250,mmio32,0xfe215040 keep_bootcon console=tty1 console=ttyS0,115200 net.ifnames=0 nokaslr
load mmc 0:1 ${kernel_addr_r} Image
load mmc 0:1 ${fdt_addr_r} DTB_TMP
booti ${kernel_addr_r} - ${fdt_addr_r}
