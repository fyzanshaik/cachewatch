#!/bin/bash

validate_release_version() {
  local version="$1"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "invalid release version: $version" >&2
    return 64
  fi
}

validate_sha256() {
  local sha256="$1"
  if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "invalid SHA-256: $sha256" >&2
    return 64
  fi
}

require_environment_variables() {
  local variable_name
  local missing=0

  for variable_name in "$@"; do
    if [[ -z "${!variable_name:-}" ]]; then
      echo "required environment variable is not set: $variable_name" >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    return 64
  fi
}

write_release_checksums() {
  local output_dir="$1"
  local version="$2"
  local app_name="Cachewatch-${version}-macos-arm64.zip"
  local cli_name="cachewatch-${version}-macos-arm64.tar.gz"

  (
    cd "$output_dir" || exit
    /usr/bin/shasum -a 256 "$app_name" "$cli_name" > SHA256SUMS
  )
}
