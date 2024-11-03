cmake_minimum_required(VERSION 3.25)
project(linux-tpmdd-test)
include(ExternalProject)

set(configs_dir "${CMAKE_SOURCE_DIR}/configs")
set(patches_dir "${CMAKE_SOURCE_DIR}/patches/buildroot")
set(buildroot_dir "${CMAKE_CURRENT_BINARY_DIR}/buildroot")

if(NOT EXISTS "${configs_dir}/${buildroot_defconfig}")
  message(FATAL_ERROR "\"${configs_dir}/${buildroot_defconfig}\" does not exist")
endif()

ExternalProject_Add(buildroot-prepare
  URL "https://buildroot.org/downloads/buildroot-2024.08.2.tar.gz"
  PREFIX buildroot
  SOURCE_DIR ${buildroot_dir}/src
  BINARY_DIR ${buildroot_dir}/build
  STAMP_DIR ${buildroot_dir}/stamp
  DOWNLOAD_DIR ${buildroot_dir}/download
  CONFIGURE_COMMAND
    ${CMAKE_MAKE_PROGRAM} -C<SOURCE_DIR> BR2_EXTERNAL=${CMAKE_SOURCE_DIR}
      O=<BINARY_DIR> ${buildroot_defconfig}
  PATCH_COMMAND patch -p1 < ${CMAKE_SOURCE_DIR}/buildroot.patch
  BUILD_COMMAND ""
  INSTALL_COMMAND ""
)
