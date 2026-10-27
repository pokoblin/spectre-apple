#!/bin/sh
# Signs a release's notarized .dmg for Sparkle and writes the appcast the Mac
# app checks for updates (App/macOS/Updates.swift):
#
#   scripts/make-appcast.sh v0.7.0 path/to/Spectre-0.7.0.dmg
#
# Then upload both the .dmg and build/Releases/appcast.xml to that GitHub
# release. The app reads the feed from the latest release
# (SPARKLE_FEED_URL in project.yml), so every release carries the whole
# appcast: this script starts from the latest one and adds the new version.
#
# Once, before the first release with updates: create the signing key with
# Sparkle's generate_keys (in the same folder as generate_appcast, below).
# The private key goes into the login Keychain, where generate_appcast finds
# it; back it up with `generate_keys -x <file>`, outside the repository:
# without it, Macs that have Spectre can't take another update. Put the
# public key it prints in SPARKLE_PUBLIC_ED_KEY in project.yml; until then
# the app has no Check for Updates….
#
# Sparkle's tools come with its package: build the app once (README) so that
# Xcode fetches it, or point SPARKLE_BIN at the bin folder of Sparkle's
# release download.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <release tag> <dmg>" >&2; exit 2; }
tag=$1
dmg=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
cd "$(dirname "$0")/.."

bin=${SPARKLE_BIN:-$(find build ~/Library/Developer/Xcode/DerivedData \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -n 1)}
[ -x "$bin/generate_appcast" ] || { echo "generate_appcast not found: set SPARKLE_BIN" >&2; exit 1; }

repo=https://github.com/pokoblin/spectre-apple
releases=build/Releases
rm -rf "$releases"
mkdir -p "$releases"
# The versions before this one. None yet: the first release with updates.
curl -fsSL "$repo/releases/latest/download/appcast.xml" -o "$releases/appcast.xml" \
    || rm -f "$releases/appcast.xml"
cp "$dmg" "$releases/"

"$bin/generate_appcast" --download-url-prefix "$repo/releases/download/$tag/" --link "$repo" "$releases"
echo "Upload $dmg and $releases/appcast.xml to $repo/releases/tag/$tag"
