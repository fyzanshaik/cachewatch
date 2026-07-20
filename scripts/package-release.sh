#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <version-or-tag> <output-directory>" >&2
  exit 64
fi

version="${1#v}"
output_dir="$2"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/release-common.sh"
derived_data="${TMPDIR:-/tmp}/cachewatch-release-${version}"
app_zip="$output_dir/Cachewatch-${version}-macos-arm64.zip"
cli_archive="$output_dir/cachewatch-${version}-macos-arm64.tar.gz"
checksums="$output_dir/SHA256SUMS"
signing_identity="${CACHEWATCH_CODE_SIGN_IDENTITY:--}"

validate_release_version "$version"

mkdir -p "$output_dir"
rm -f "$app_zip" "$cli_archive" "$checksums"

build_settings=(
  "MARKETING_VERSION=$version"
  "CODE_SIGN_IDENTITY=$signing_identity"
)

if [[ "$signing_identity" != "-" ]]; then
  require_environment_variables CACHEWATCH_DEVELOPMENT_TEAM
  build_settings+=(
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=$CACHEWATCH_DEVELOPMENT_TEAM"
    "ENABLE_HARDENED_RUNTIME=YES"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
fi

xcodebuild -quiet \
  -project "$repo_root/Cachewatch.xcodeproj" \
  -scheme Cachewatch \
  -destination "platform=macOS,arch=arm64" \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  "${build_settings[@]}" \
  clean build

app="$derived_data/Build/Products/Release/Cachewatch.app"
plist="$app/Contents/Info.plist"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "com.fyzanshaik.cachewatch"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"
codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip"

/usr/bin/swift build \
  --package-path "$repo_root" \
  -c release \
  --triple arm64-apple-macosx15.0
bin_path="$(/usr/bin/swift build --package-path "$repo_root" -c release --triple arm64-apple-macosx15.0 --show-bin-path)"
/usr/bin/tar -C "$bin_path" -czf "$cli_archive" Cachewatch

write_release_checksums "$output_dir" "$version"

echo "$app_zip"
echo "$cli_archive"
echo "$checksums"
