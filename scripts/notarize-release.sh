#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app-zip>" >&2
  exit 64
fi

app_archive="$1"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/release-common.sh"

require_environment_variables \
  APPLE_ID \
  APPLE_TEAM_ID \
  APPLE_APP_SPECIFIC_PASSWORD

app_filename="$(basename "$app_archive")"
if [[ ! "$app_filename" =~ ^Cachewatch-([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)-macos-arm64\.zip$ ]]; then
  echo "invalid app archive name: $app_filename" >&2
  exit 64
fi
version="${BASH_REMATCH[1]}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/cachewatch-notarize.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

notary_credentials=(
  --apple-id "$APPLE_ID"
  --password "$APPLE_APP_SPECIFIC_PASSWORD"
  --team-id "$APPLE_TEAM_ID"
)

xcrun notarytool submit \
  "$app_archive" \
  "${notary_credentials[@]}" \
  --wait \
  --timeout 30m

/usr/bin/ditto -x -k "$app_archive" "$scratch/app"
app="$scratch/app/Cachewatch.app"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

notarized_archive="$scratch/$app_filename"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$notarized_archive"
/bin/mv "$notarized_archive" "$app_archive"

write_release_checksums "$(dirname "$app_archive")" "$version"

echo "Cachewatch ${version} notarization passed"
