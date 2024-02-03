cmake_minimum_required(VERSION 3.20)

project(ib-vanilla-superbuild)

include(ExternalProject)


# Build vanilla

## Create a pkg-config that finds pc files in INSTALL_DIR
ExternalProject_Add(pkg-config
SOURCE_DIR
  ${CMAKE_CURRENT_SOURCE_DIR}/../pkg-config
INSTALL_DIR
  ${CMAKE_INSTALL_PREFIX}
CMAKE_CACHE_ARGS
  -DCMAKE_INSTALL_PREFIX:PATH=<INSTALL_DIR>
)

ExternalProject_Add(sodium
  URL https://download.libsodium.org/libsodium/releases/libsodium-1.0.19-stable.tar.gz
  # the "stable" target may change, don't set a hash
  # DOWNLOAD_EXTRACT_TIMESTAMP TRUE # 3.24
  INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
  CONFIGURE_COMMAND <SOURCE_DIR>/configure --srcdir=<SOURCE_DIR> --prefix=<INSTALL_DIR>
  BUILD_COMMAND make -j32 
  TEST_BEFORE_INSTALL true
  TEST_COMMAND make check
  INSTALL_COMMAND make install
)


ExternalProject_Add(rdma-core
  DEPENDS
    pkg-config
  SOURCE_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../../rdma-core-49.0
  INSTALL_DIR
    ${CMAKE_INSTALL_PREFIX}
  CMAKE_ARGS
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DNO_PYVERBS=1
    -DNO_MAN_PAGES=1
  CMAKE_CACHE_ARGS
    -DCMAKE_INSTALL_PREFIX:PATH=<INSTALL_DIR>
    -DCMAKE_PREFIX_PATH:PATH=<INSTALL_DIR>
  BUILD_ALWAYS 1
  )
