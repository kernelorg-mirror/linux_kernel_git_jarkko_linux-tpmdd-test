#!/usr/bin/env bash

set -e

BOARD_DIR="$(dirname "$0")"

support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"
support/scripts/genimage.sh -c "${BOARD_DIR}/genimage_spi-nor.cfg"
