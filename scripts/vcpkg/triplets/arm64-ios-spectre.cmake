# arm64 ios, static libraries, release only (vcpkg builds each port once).
# Used by scripts/build-gdpcore.sh; arm64-osx-spectre is also the host triplet (protoc).
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 27.0)
set(VCPKG_BUILD_TYPE release)
