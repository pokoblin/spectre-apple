#!/bin/sh
# Brings the String Catalogs up to date with the code: builds the app for
# macOS and the iOS simulator, collects the strings the compiler found
# (.stringsdata), and merges them into App/Shared/Localizable.xcstrings and
# SpectreKit's. New strings arrive untranslated, strings no longer in the code
# are marked stale; the translations themselves are edited in the catalogs
# (Xcode, or by hand). LocalizationTests then fail until every language has
# every string. See docs/localization.md.
set -eu
cd "$(dirname "$0")/.."

derived=build/DerivedData-strings
xcodegen generate --quiet
for destination in 'generic/platform=macOS' 'generic/platform=iOS Simulator'; do
    xcodebuild -project Spectre.xcodeproj -scheme Spectre -configuration Debug \
        -destination "$destination" -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO build -quiet
done

# sync <catalog> <directory pattern>: merge the .stringsdata found under it.
sync() {
    catalog=$1
    pattern=$2
    set --
    for file in $(find "$derived/Build/Intermediates.noindex" -path "$pattern" -name '*.stringsdata'); do
        set -- "$@" --stringsdata "$file"
    done
    xcrun xcstringstool sync "$catalog" "$@"
    echo "$catalog: $(xcrun xcstringstool print "$catalog" | wc -l | tr -d ' ') strings"
}
sync App/Shared/Localizable.xcstrings '*/Spectre.build/*'
sync Packages/SpectreKit/Sources/SpectreKit/Localizable.xcstrings '*/SpectreKit*.build/*'
