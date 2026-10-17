#!/usr/bin/env bash
# Builds Packages/SpectreKit/Artifacts/PyroWave.xcframework: the native Metal
# port of the PyroWave codec (third_party/pyrowave/metal), one static library
# per platform. It needs neither Granite nor Vulkan: its shaders are MSL,
# committed upstream as source strings and compiled when a device is created.
#
#   scripts/build-pyrowave.sh                   # macos ios ios-simulator
#   scripts/build-pyrowave.sh macos             # just some platforms
#
# PyroWave's bitstream isn't stable yet, so both ends must be built from the
# same revision (gdp-spec.md §6.6): the one ghost pins in
# packaging/build-pyrowave.sh. The submodule must be checked out there.
#
# Environment:
#   CONFIGURATION   Release (default) or Debug
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-Release}
DEPLOYMENT_TARGET=27.0
SRC=$ROOT/third_party/pyrowave/metal
BUILD=$ROOT/build/pyrowave
XCFRAMEWORK=$ROOT/Packages/SpectreKit/Artifacts/PyroWave.xcframework

platforms=("$@")
[ ${#platforms[@]} -eq 0 ] && platforms=(macos ios ios-simulator)

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC/pyrowave_metal.h" ] || die "third_party/pyrowave is empty: git submodule update --init"
pin=$(sed -n 's/^PYROWAVE_COMMIT=\([0-9a-f]*\).*/\1/p' "$ROOT/third_party/ghost/packaging/build-pyrowave.sh")
[ -n "$pin" ] || die "no PYROWAVE_COMMIT in third_party/ghost/packaging/build-pyrowave.sh"
head=$(git -C "$ROOT/third_party/pyrowave" rev-parse HEAD)
[ "$head" = "$pin" ] || die "third_party/pyrowave is at ${head:0:7}, ghost pins ${pin:0:7}"
for tool in xcrun xcodebuild libtool; do
	command -v $tool >/dev/null || die "$tool not found"
done

case $CONFIGURATION in
	Release) opt=(-O2 -DNDEBUG) ;;
	Debug) opt=(-O0 -g) ;;
	*) die "CONFIGURATION must be Release or Debug" ;;
esac

build_platform() {
	local platform=$1 sdk target
	case $platform in
		macos) sdk=macosx; target=arm64-apple-macos$DEPLOYMENT_TARGET ;;
		ios) sdk=iphoneos; target=arm64-apple-ios$DEPLOYMENT_TARGET ;;
		ios-simulator) sdk=iphonesimulator; target=arm64-apple-ios$DEPLOYMENT_TARGET-simulator ;;
		*) die "unknown platform '$platform' (macos, ios, ios-simulator)" ;;
	esac
	local dir=$BUILD/$platform
	rm -rf "$dir"
	# Headers in a subdirectory: GDPCore.xcframework's module map already
	# sits at the root of the include directory SwiftPM merges them into.
	local include=$dir/out/include/PyroWave
	mkdir -p "$dir/obj" "$dir/out/lib" "$include"

	log "$platform: compile ($CONFIGURATION)"
	local sysroot
	sysroot=$(xcrun --sdk $sdk --show-sdk-path)
	# Upstream's own flags (metal/CMakeLists.txt), static instead of shared:
	# PYROWAVE_PUBLIC_API stays empty, and -fvisibility=hidden keeps the
	# symbols out of the app's exports.
	local flags=(-target "$target" -isysroot "$sysroot" -std=c++14 "${opt[@]}"
		-fvisibility=hidden -Wall -Wextra -Wshadow -I"$SRC")
	for f in pyrowave_common.mm pyrowave_decoder.mm pyrowave_encoder.mm pyrowave_bitstream.cpp; do
		local extra=()
		[[ $f == *.mm ]] && extra=(-fobjc-arc)
		xcrun --sdk $sdk clang++ "${flags[@]}" ${extra[@]+"${extra[@]}"} \
			-c "$SRC/$f" -o "$dir/obj/${f%.*}.o" 2>>"$dir/compile.log" \
			|| { cat "$dir/compile.log"; die "compiling $f failed"; }
	done
	libtool -static -o "$dir/out/lib/libPyroWave.a" "$dir"/obj/*.o
	cp "$SRC/pyrowave_metal.h" "$include/"
	cat >"$include/module.modulemap" <<-'EOF'
	module PyroWave {
	    header "pyrowave_metal.h"
	    link framework "Metal"
	    link framework "IOSurface"
	    export *
	}
	EOF
	printf '    %s (%s)\n' "$dir/out/lib/libPyroWave.a" "$(du -h "$dir/out/lib/libPyroWave.a" | cut -f1)"
}

for p in "${platforms[@]}"; do
	build_platform "$p"
done

log "assemble $(basename "$XCFRAMEWORK")"
args=()
for p in macos ios ios-simulator; do
	if [ -f "$BUILD/$p/out/lib/libPyroWave.a" ]; then
		args+=(-library "$BUILD/$p/out/lib/libPyroWave.a" -headers "$BUILD/$p/out/include")
	fi
done
rm -rf "$XCFRAMEWORK"
mkdir -p "$(dirname "$XCFRAMEWORK")"
xcodebuild -create-xcframework "${args[@]}" -output "$XCFRAMEWORK" >/dev/null
plutil -extract AvailableLibraries json -o - "$XCFRAMEWORK/Info.plist" \
	| /usr/bin/python3 -c 'import json,sys; [print("    slice:", l["LibraryIdentifier"]) for l in json.load(sys.stdin)]'
