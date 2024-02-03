#!/usr/bin/env bash
set -u

if [[ $# -lt 4 ]]; then
    printf "%s SOURCE_DIR BUILD_DIR INSTALL_DIR BUILD_TYPE\n" $0
    exit
fi

SOURCE_DIR="$1"
BUILD_DIR="$2"
INSTALL_DIR="$3"


BR_SRC="$SOURCE_DIR/cvmrdma-buildroot"
# build in installdir as the resulting assets will be in the build dir
BR_BUILD="$INSTALL_DIR/br-qemu-$BUILD_TYPE" 

make -C "$BR_SRC" O="$BR_BUILD" cvmrdma_qemu_defconfig
cat <<EOF > "$BR_BUILD/local.mk"
RDMA_CORE_CVMRDMA_OVERRIDE_SRCDIR="$(realpath "$SOURCE_DIR/cvmrdma-rdma-core")"
EOF

# LINUX_OVERRIDE_SRCDIR="$(realpath "$SOURCE_DIR/cvmrdma-linux")"
# QEMU_OVERRIDE_SRCDIR="$(realpath "$SOURCE_DIR/cvmrdma-qemu")"


if [[ $BUILD_TYPE = "Debug" ]]; then
cat <<EOF >> "$BR_BUILD/.config"
BR2_ENABLE_DEBUG=y
BR2_ENABLE_RUNTIME_DEBUG=y
BR2_PACKAGE_GDB=y # for gdbserver
EOF
make -C "$BR_BUILD" olddefconfig
fi
