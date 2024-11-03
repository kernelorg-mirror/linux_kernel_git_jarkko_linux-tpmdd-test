#!/usr/bin/env bash

set -e

SSH_DIR="${TARGET_DIR}/root/.ssh"
echo "SSH_DIR=$SSH_DIR"

mkdir -p "$SSH_DIR"

ssh-keygen -C 'root@tpmdd' -t rsa -f "$SSH_DIR/id-rsa" -N ''
cp -f $SSH_DIR/{id-rsa.pub,authorized_keys}
