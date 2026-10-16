# GDPCore: libgdp (from the ghost submodule, as checked out) plus the C ABI in
# include/gdpcore.h. scripts/build-gdpcore.sh configures this once per
# platform with vcpkg's toolchain, then merges the static libraries into
# GDPCore.xcframework.
cmake_minimum_required(VERSION 3.25)
project(GDPCore VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

get_filename_component(GHOST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/ghost" ABSOLUTE)
if(NOT EXISTS "${GHOST_DIR}/libgdp/CMakeLists.txt")
  message(FATAL_ERROR "${GHOST_DIR} is empty: run `git submodule update --init`")
endif()

# EXCLUDE_FROM_ALL: only what gdpcore links gets built -- libgdp's own test
# executables are declared unconditionally and aren't wanted here (on iOS
# they couldn't even run).
add_subdirectory("${GHOST_DIR}/libgdp" libgdp EXCLUDE_FROM_ALL)

find_package(OpenSSL REQUIRED)

add_library(gdpcore STATIC
  src/gdpcore.cpp
  src/cert_util.cpp
  src/selftest.cpp
  src/receive_stats.cpp
  src/session_client.cpp
  src/session_api.cpp
  src/test_host.cpp
  src/server_loop.cpp
  src/lobby_api.cpp
  src/test_lobby.cpp
)
target_include_directories(gdpcore PUBLIC include)
target_link_libraries(gdpcore PRIVATE gdp OpenSSL::Crypto)
target_compile_options(gdpcore PRIVATE -Wall -Wextra -Wno-unused-parameter)
