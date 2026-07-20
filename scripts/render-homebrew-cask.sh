#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version-or-tag> <app-zip-sha256> <output-file>" >&2
  exit 64
fi

version="${1#v}"
sha256="$2"
output_file="$3"
source "$(dirname "$0")/release-common.sh"

validate_release_version "$version"
validate_sha256 "$sha256"

mkdir -p "$(dirname "$output_file")"
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha256/g" \
  "$(dirname "$0")/../packaging/cachewatch.rb.in" > "$output_file"
