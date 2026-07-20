#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <app-zip> <expected-version> [--require-notarization]" >&2
  exit 64
fi

archive="$1"
expected_version="${2#v}"
verification_mode="${3:-}"
if [[ -n "$verification_mode" && "$verification_mode" != "--require-notarization" ]]; then
  echo "unknown verification mode: $verification_mode" >&2
  exit 64
fi
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
if [[ "$verification_mode" == "--require-notarization" ]]; then
  signature_details="$(codesign --display --verbose=4 "$app" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<< "$signature_details"
  grep -q '^Timestamp=' <<< "$signature_details"
  grep -q 'flags=.*runtime' <<< "$signature_details"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
fi
test "$("$executable" --version)" = "$expected_version"

mkdir "$scratch/cli"
/usr/bin/tar -C "$scratch/cli" -xzf "$cli_archive"
test "$(/usr/bin/lipo -archs "$scratch/cli/Cachewatch")" = "arm64"
test "$(CACHEWATCH_VERSION="$expected_version" "$scratch/cli/Cachewatch" --version)" = "$expected_version"

echo "Cachewatch ${expected_version} package passed"
