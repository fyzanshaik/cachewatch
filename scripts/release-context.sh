#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <event-name> <ref-name> <manual-version>" >&2
  exit 64
fi

event_name="$1"
ref_name="$2"
manual_version="$3"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-common.sh
source "$repo_root/scripts/release-common.sh"

case "$event_name" in
  push)
    if [[ "$ref_name" != v* ]]; then
      echo "release push must reference a version tag: $ref_name" >&2
      exit 64
    fi
    release_tag="$ref_name"
    publish=true
    ;;
  workflow_dispatch)
    release_tag="v${manual_version#v}"
    publish=false
    ;;
  *)
    echo "unsupported release event: $event_name" >&2
    exit 64
    ;;
esac

validate_release_version "${release_tag#v}"
printf 'CACHEWATCH_RELEASE_TAG=%s\n' "$release_tag"
printf 'CACHEWATCH_PUBLISH=%s\n' "$publish"
