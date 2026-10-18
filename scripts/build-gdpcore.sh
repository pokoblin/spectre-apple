#!/usr/bin/env bash
# Builds Packages/GDPKit/Artifacts/GDPCore.xcframework: libgdp (from the
# ghost submodule, as checked out), its dependencies (vcpkg, static) and the C
# ABI in Packages/GDPKit/Native, merged into one static library per platform.
#
#   scripts/build-gdpcore.sh                    # macos ios ios-simulator
#   scripts/build-gdpcore.sh macos              # just some platforms
#
# The xcframework is assembled from every platform built so far under
# build/gdpcore/, so platforms can be built one at a time.
#
# Environment:
#   VCPKG_ROOT   vcpkg checkout (default ~/src/vcpkg; upstream CI pins 07f48122)
#   BUILD_TYPE   CMake build type for gdpcore/libgdp (default RelWithDebInfo;
#                vcpkg dependencies are always release, see scripts/vcpkg/triplets)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VCPKG_ROOT=${VCPKG_ROOT:-$HOME/src/vcpkg}
BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}
DEPLOYMENT_TARGET=27.0
HOST_TRIPLET=arm64-osx-spectre
NATIVE=$ROOT/Packages/GDPKit/Native
BUILD=$ROOT/build/gdpcore
XCFRAMEWORK=$ROOT/Packages/GDPKit/Artifacts/GDPCore.xcframework

platforms=("$@")
[ ${#platforms[@]} -eq 0 ] && platforms=(macos ios ios-simulator)

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -x "$VCPKG_ROOT/vcpkg" ] || die "no vcpkg at $VCPKG_ROOT (set VCPKG_ROOT; bootstrap with ./bootstrap-vcpkg.sh)"
[ -f "$ROOT/third_party/ghost/libgdp/CMakeLists.txt" ] || die "third_party/ghost is empty: git submodule update --init"
for tool in cmake ninja xcodebuild libtool; do
	command -v $tool >/dev/null || die "$tool not found"
done

build_platform() {
	local platform=$1 triplet system sysroot
	case $platform in
		macos) triplet=arm64-osx-spectre; system=Darwin; sysroot=macosx ;;
		ios) triplet=arm64-ios-spectre; system=iOS; sysroot=iphoneos ;;
		ios-simulator) triplet=arm64-ios-simulator-spectre; system=iOS; sysroot=iphonesimulator ;;
		*) die "unknown platform '$platform' (macos, ios, ios-simulator)" ;;
	esac
	local installed=$ROOT/build/vcpkg/$triplet
	local dir=$BUILD/$platform
	mkdir -p "$dir" "$ROOT/build/logs"

	log "$platform: vcpkg dependencies ($triplet)"
	"$VCPKG_ROOT/vcpkg" install \
		--x-manifest-root="$ROOT/scripts/vcpkg" \
		--x-install-root="$installed" \
		--overlay-triplets="$ROOT/scripts/vcpkg/triplets" \
		--triplet="$triplet" --host-triplet="$HOST_TRIPLET" \
		>"$ROOT/build/logs/vcpkg-$platform.log" 2>&1 \
		|| die "vcpkg install failed, see build/logs/vcpkg-$platform.log"

	log "$platform: configure + build gdpcore ($BUILD_TYPE)"
	local system_args=()
	[ "$system" = iOS ] && system_args=(-DCMAKE_SYSTEM_NAME=iOS)
	cmake -S "$NATIVE" -B "$dir/cmake" -G Ninja \
		-DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
		${system_args[@]+"${system_args[@]}"} \
		-DCMAKE_OSX_SYSROOT="$sysroot" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
		-DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
		-DVCPKG_MANIFEST_MODE=OFF \
		-DVCPKG_INSTALLED_DIR="$installed" \
		-DVCPKG_TARGET_TRIPLET="$triplet" \
		-DVCPKG_HOST_TRIPLET="$HOST_TRIPLET" \
		-DGHOST_ENABLE_FUSE=OFF \
		>"$ROOT/build/logs/cmake-$platform.log" 2>&1 \
		|| die "cmake configure failed, see build/logs/cmake-$platform.log"
	cmake --build "$dir/cmake" --target gdpcore >>"$ROOT/build/logs/cmake-$platform.log" 2>&1 \
		|| die "build failed, see build/logs/cmake-$platform.log"

	log "$platform: merge static libraries"
	local lib=$installed/$triplet/lib
	# What gdpcore + libgdp link, transitively: protobuf (full, not -lite)
	# with abseil and utf8_range, ngtcp2 with its OpenSSL crypto helper,
	# OpenSSL, zstd. Not protoc/upb (the compiler) or protobuf-lite (it
	# duplicates libprotobuf's symbols).
	local inputs=(
		"$dir/cmake/libgdpcore.a"
		"$dir/cmake/libgdp/libgdp.a"
		"$lib/libprotobuf.a" "$lib/libutf8_validity.a" "$lib/libutf8_range.a"
		"$lib"/libabsl_*.a
		"$lib/libngtcp2_crypto_ossl.a" "$lib/libngtcp2.a"
		"$lib/libssl.a" "$lib/libcrypto.a"
		"$lib/libzstd.a"
	)
	for f in "${inputs[@]}"; do [ -f "$f" ] || die "missing $f"; done
	mkdir -p "$dir/out/lib" "$dir/out/include"
	libtool -static -no_warning_for_no_symbols -o "$dir/out/lib/libGDPCore.a" "${inputs[@]}" 2>"$dir/libtool.log" \
		|| { cat "$dir/libtool.log"; die "libtool failed"; }
	cp "$NATIVE/include/gdpcore.h" "$NATIVE/include/module.modulemap" "$dir/out/include/"
	printf '    %s (%s)\n' "$dir/out/lib/libGDPCore.a" "$(du -h "$dir/out/lib/libGDPCore.a" | cut -f1)"
}

for p in "${platforms[@]}"; do
	build_platform "$p"
done

log "assemble $(basename "$XCFRAMEWORK")"
args=()
for p in macos ios ios-simulator; do
	if [ -f "$BUILD/$p/out/lib/libGDPCore.a" ]; then
		args+=(-library "$BUILD/$p/out/lib/libGDPCore.a" -headers "$BUILD/$p/out/include")
	fi
done
rm -rf "$XCFRAMEWORK"
mkdir -p "$(dirname "$XCFRAMEWORK")"
xcodebuild -create-xcframework "${args[@]}" -output "$XCFRAMEWORK" >/dev/null
plutil -extract AvailableLibraries json -o - "$XCFRAMEWORK/Info.plist" \
	| /usr/bin/python3 -c 'import json,sys; [print("    slice:", l["LibraryIdentifier"]) for l in json.load(sys.stdin)]'
