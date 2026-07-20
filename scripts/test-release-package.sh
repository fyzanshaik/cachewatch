#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-zip> <expected-version>" >&2
  exit 64
fi

archive="$1"
expected_version="${2#v}"
cli_archive="$(dirname "$archive")/cachewatch-${expected_version}-macos-arm64.tar.gz"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cachewatch-package-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

/usr/bin/ditto -x -k "$archive" "$scratch"
app="$scratch/Cachewatch.app"
executable="$app/Contents/MacOS/Cachewatch"
plist="$app/Contents/Info.plist"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "com.fyzanshaik.cachewatch"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$expected_version"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"
test "$(/usr/bin/lipo -archs "$executable")" = "arm64"
test -f "$app/Contents/Resources/AppIcon.icns"
test -f "$app/Contents/Resources/Assets.car"
codesign --verify --deep --strict "$app"
test "$("$executable" --version)" = "$expected_version"

mkdir "$scratch/cli"
/usr/bin/tar -C "$scratch/cli" -xzf "$cli_archive"
test "$(/usr/bin/lipo -archs "$scratch/cli/Cachewatch")" = "arm64"
test "$(CACHEWATCH_VERSION="$expected_version" "$scratch/cli/Cachewatch" --version)" = "$expected_version"

echo "Cachewatch ${expected_version} package passed"
