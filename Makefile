
SOURCE_DIR:=$(CURDIR)/..
BUILD_DIR:=${HOME}/cvmrdma-build
INSTALL_DIR:=${HOME}/cvmrdma-install

BUILD_TYPE=Release

all: client

X86_VER=3
.PHONY: toolchain
toolchain:
	./scripts/dl_toolchain.sh ${SOURCE_DIR} ${BUILD_DIR} ${INSTALL_DIR} ${X86_VER}


CVMRDMA_BUILDDIR=${BUILD_DIR}/cvmrdma-$(BUILD_TYPE)
CVMRDMA_INSTALLDIR=${INSTALL_DIR}/cvmrdma-$(BUILD_TYPE)
.PHONY: cvmrdma
cvmrdma:
	cmake -S cvmrdma -B $(CVMRDMA_BUILDDIR) -DCMAKE_INSTALL_PREFIX=$(CVMRDMA_INSTALLDIR) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -GNinja
	PKG_CONFIG=${CVMRDMA_INSTALLDIR}/bin/pkg-config cmake --build ${CVMRDMA_BUILDDIR}


VANILLA_BUILDDIR=${BUILD_DIR}/vanilla-$(BUILD_TYPE)
VANILLA_INSTALLDIR=${INSTALL_DIR}/vanilla-$(BUILD_TYPE)
.PHONY: vanilla
vanilla:
	cmake -S vanilla -B ${VANILLA_BUILDDIR} -DCMAKE_INSTALL_PREFIX=${VANILLA_INSTALLDIR} -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -GNinja
	PKG_CONFIG=${VANILLA_INSTALLDIR}/bin/pkg-config cmake --build ${VANILLA_BUILDDIR}


.PHONY: br-sev
br-sev:
	./scripts/prepare_br_sev.sh ${SOURCE_DIR} ${BUILD_DIR} ${INSTALL_DIR} ${BUILD_TYPE}
	$(MAKE) -C "${INSTALL_DIR}/br-sev-${BUILD_TYPE}"