
SOURCE_DIR:=$(CURDIR)/..
BUILD_DIR:=${HOME}/cvmrdma-build
INSTALL_DIR:=${HOME}/cvmrdma-install

BUILD_TYPE=Debug

all: client

.PHONY: toolchain
toolchain:
	./scripts/dl_toolchain.sh ${SOURCE_DIR} ${BUILD_DIR} ${INSTALL_DIR}


.PHONY: client
client:
	cmake -S rpc-client -B ${BUILD_DIR}/client -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/client -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -GNinja
	PKG_CONFIG=${INSTALL_DIR}/client/bin/pkg-config cmake --build ${BUILD_DIR}/client

.PHONY: vanilla
vanilla:
	cmake -S vanilla -B ${BUILD_DIR}/vanilla -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/vanilla -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -GNinja
	PKG_CONFIG=${INSTALL_DIR}/vanilla/bin/pkg-config cmake --build ${BUILD_DIR}/vanilla


.PHONY: br-cvm
br-cvm:
	./scripts/build_br_cvm.sh ${SOURCE_DIR} ${BUILD_DIR} ${INSTALL_DIR}
