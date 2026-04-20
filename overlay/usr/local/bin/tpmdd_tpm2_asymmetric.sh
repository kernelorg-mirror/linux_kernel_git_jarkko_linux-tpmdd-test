#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>
#
# Cross-verification test for TPM2 asymmetric keys.

set -e

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"; tpm2_clear' EXIT

openssl ecparam -genkey -name prime256v1 -noout -out "$WORKDIR/ec_key.pem"

tpm2_createprimary --hierarchy o -G ecc -c "$WORKDIR/primary.ctx"
tpm2_evictcontrol -C o -c "$WORKDIR/primary.ctx" 0x81000001

tpm2_import -C 0x81000001 -G ecc \
	-i "$WORKDIR/ec_key.pem" \
	-u "$WORKDIR/key.pub" -r "$WORKDIR/key.priv"

tpm2_encodeobject -C 0x81000001 \
	-u "$WORKDIR/key.pub" -r "$WORKDIR/key.priv" \
	-o "$WORKDIR/tpm2_key.pem"
openssl asn1parse -inform pem -in "$WORKDIR/tpm2_key.pem" \
	-noout -out "$WORKDIR/tpm2_key.der"

openssl req -new -x509 -key "$WORKDIR/ec_key.pem" \
	-out "$WORKDIR/cert.pem" -days 1 \
	-subj "/CN=tpm2_asymmetric_test" -sha256
openssl x509 -in "$WORKDIR/cert.pem" -outform der -out "$WORKDIR/cert.der"

TPM2_KEY=$(keyctl padd asymmetric "tpm2_ecdsa" @u < "$WORKDIR/tpm2_key.der")
X509_KEY=$(keyctl padd asymmetric "x509_ecdsa" @u < "$WORKDIR/cert.der")

printf "tpm2 asymmetric cross-verification test data" > "$WORKDIR/testdata"
openssl dgst -sha256 -binary "$WORKDIR/testdata" > "$WORKDIR/hash.bin"

keyctl pkey_sign $TPM2_KEY 0 "$WORKDIR/hash.bin" enc=x962 hash=sha256 \
	> "$WORKDIR/sig_tpm.der"
keyctl pkey_verify $X509_KEY 0 "$WORKDIR/hash.bin" "$WORKDIR/sig_tpm.der" \
	enc=x962 hash=sha256
echo "PASS: TPM2 key signed, X.509 key verified"

openssl dgst -sha256 -sign "$WORKDIR/ec_key.pem" \
	-out "$WORKDIR/sig_sw.der" "$WORKDIR/testdata"
keyctl pkey_verify $TPM2_KEY 0 "$WORKDIR/hash.bin" "$WORKDIR/sig_sw.der" \
	enc=x962 hash=sha256
echo "PASS: OpenSSL signed, TPM2 key verified"
