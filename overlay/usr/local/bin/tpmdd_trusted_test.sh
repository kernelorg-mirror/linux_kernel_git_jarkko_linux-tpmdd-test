#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

handle=$(tpm2sh create-primary rsa-2048:sha256)
tpm2sh evict "$handle" 81000001
keyctl add trusted kmk 'new 32 keyhandle=0x81000001' @u
keyctl add encrypted 1000100010001000 'new ecryptfs trusted:kmk 64' @u
keyctl list @u | grep -q "2 keys in keyring:"
tpm2sh delete '*'
