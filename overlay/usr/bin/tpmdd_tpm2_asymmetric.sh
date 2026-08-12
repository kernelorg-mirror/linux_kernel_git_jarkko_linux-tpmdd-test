#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>
#
# Cross-verification test for TPM2 asymmetric keys.

set -e

export TPM2TOOLS_TCTI="${TPM2TOOLS_TCTI:-device:/dev/tpmrm0}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; tpm2_clear' EXIT

openssl ecparam -genkey -name prime256v1 -noout -out "$WORK/ec_key.pem"

tpm2_createprimary --hierarchy o -G ecc -c "$WORK/primary.ctx"
tpm2_evictcontrol -C o -c "$WORK/primary.ctx" 0x81000001

tpm2_import -C 0x81000001 -G ecc \
  -i "$WORK/ec_key.pem" \
  -u "$WORK/key.pub" -r "$WORK/key.priv"

tpm2_encodeobject -C 0x81000001 \
  -u "$WORK/key.pub" -r "$WORK/key.priv" \
  -o "$WORK/tpm2_key.pem"
openssl asn1parse -inform pem -in "$WORK/tpm2_key.pem" \
  -noout -out "$WORK/tpm2_key.der"

openssl req -new -x509 -key "$WORK/ec_key.pem" \
  -out "$WORK/cert.pem" -days 1 \
  -subj "/CN=tpm2_asymmetric_test" -sha256
openssl x509 -in "$WORK/cert.pem" -outform der -out "$WORK/cert.der"

TPM2_KEY=$(keyctl padd asymmetric "tpm2_asymmetric" @s < "$WORK/tpm2_key.der")
X509_KEY=$(keyctl padd asymmetric "x509_ecdsa" @s < "$WORK/cert.der")

printf "tpm2 asymmetric cross-verification test data" > "$WORK/testdata"
openssl dgst -sha256 -binary "$WORK/testdata" > "$WORK/hash.bin"

keyctl pkey_sign $TPM2_KEY 0 "$WORK/hash.bin" enc=x962 hash=sha256 \
  > "$WORK/sig_tpm.der"
keyctl pkey_verify $X509_KEY 0 "$WORK/hash.bin" "$WORK/sig_tpm.der" \
  enc=x962 hash=sha256
echo "PASS: TPM2 key signed, X.509 key verified"

openssl dgst -sha256 -sign "$WORK/ec_key.pem" \
  -out "$WORK/sig_sw.der" "$WORK/testdata"
keyctl pkey_verify $TPM2_KEY 0 "$WORK/hash.bin" "$WORK/sig_sw.der" \
  enc=x962 hash=sha256
echo "PASS: OpenSSL signed, TPM2 key verified"
