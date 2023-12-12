#!/usr/bin/env bash
set -uo pipefail

if [[ $# -ne 3 ]]; then
    printf "%s SOURCE_DIR BUILD_DIR INSTALL_DIR\n" "$0"
    exit
fi

SOURCE_DIR="$1"
BUILD_DIR="$2"
INSTALL_DIR="$3"


ARCH="x86-64-v4"
TOOLCHAIN_NAME="x86-64-v4--glibc--bleeding-edge-2023.08-1.tar.bz2"
SHA256="59cc1a8d860fd63a597efa863a47dfdecb489723678dfee6386e0970fb556693"

TOOLCHAIN_URI="https://toolchains.bootlin.com/downloads/releases/toolchains/${ARCH}/tarballs/${TOOLCHAIN_NAME}"
TMP="$(mktemp -d)"
ARCHIVE="$TMP/$TOOLCHAIN_NAME" 
DEST="$INSTALL_DIR/toolchain"


wget "$TOOLCHAIN_URI" -O "$ARCHIVE" || { echo "Download failed!"; exit 1; }

{ echo "$SHA256 $ARCHIVE" | sha256sum -c; } || { echo "sha256 validation failed!"; exit 1; }

tar xf "$ARCHIVE" --strip-components=1 -C "$TMP" || { echo "Extraction failed."; exit 1; }

if [[ -d "$DEST" ]]; then
    echo "Removing old toolchain at '$DEST'..."
    rm -r "$DEST" || { echo "Removing old toolchain failed."; exit 1; }
fi


mkdir -p $INSTALL_DIR
mv "$TMP" "$DEST" &&
cd "$DEST" &&
./relocate-sdk.sh