#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

set -e

SSH_DIR="${TARGET_DIR}/root/.ssh"
echo "SSH_DIR=$SSH_DIR"

mkdir -p -m 700 "$SSH_DIR"

if [ ! -f "$SSH_DIR/id-rsa" ]; then
  ssh-keygen -C 'root@tpmdd' -t rsa -f "$SSH_DIR/id-rsa" -N ''
  cp -f "$SSH_DIR"/{id-rsa.pub,authorized_keys}
  chmod 600 "$SSH_DIR/authorized_keys"
fi
