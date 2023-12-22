#!/usr/bin/env bash
set -uo pipefail

if [[ $# -le 3 ]]; then
    printf "%s SOURCE_DIR BUILD_DIR INSTALL_DIR [x86 VER]\n" "$0"
    exit
fi

SOURCE_DIR="$1"
BUILD_DIR="$2"
INSTALL_DIR="$3"

X86_VER="2"
if [[ $# -le 4 ]]; then
    X86_VER="$4"
fi


TOOLCHAINS_SHA256=(
    ""
    "e896274d4c540a45da02c1a167264116314b5e3afd298b79f28554b0f4eb498d"
    "dbb470879dff87a6a99f6736959f5b38f6cce665b1f9c56c1c6450663c0f07de"
    "8c2a9de04b56a33ca55190e4479d5ebea17e853fd1ad38eb4750868f2bf459ee"
    "59cc1a8d860fd63a597efa863a47dfdecb489723678dfee6386e0970fb556693"
)
SHA256="${TOOLCHAINS_SHA256[$X86_VER]}"

ARCH="x86-64"
if [[ $X86_VER -gt "1" ]]; then
    ARCH="x86-64-v$X86_VER"
fi

TOOLCHAIN_NAME="$ARCH--glibc--bleeding-edge-2023.08-1.tar.bz2"


TOOLCHAIN_URI="https://toolchains.bootlin.com/downloads/releases/toolchains/${ARCH}/tarballs/${TOOLCHAIN_NAME}"
TMP="$(mktemp -d)"
ARCHIVE="$TMP/$TOOLCHAIN_NAME" 
DEST="$INSTALL_DIR/toolchain-$ARCH"


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