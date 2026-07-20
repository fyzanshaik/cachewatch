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
