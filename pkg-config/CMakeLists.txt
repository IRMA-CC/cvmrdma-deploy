cmake_minimum_required(VERSION 3.20)

project(cvmrdma-pkg-config)

include(GNUInstallDirs)

# Pkg-config for this install path
configure_file(
  ${CMAKE_CURRENT_SOURCE_DIR}/pkg-config.in
  bin/pkg-config
)
install(PROGRAMS ${CMAKE_CURRENT_BINARY_DIR}/bin/pkg-config TYPE BIN)