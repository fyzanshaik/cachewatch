#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
context_script="$repo_root/scripts/release-context.sh"
workflow="$repo_root/.github/workflows/release.yml"

push_context="$("$context_script" push v0.3.0 '')"
grep -Fxq 'CACHEWATCH_RELEASE_TAG=v0.3.0' <<< "$push_context"
grep -Fxq 'CACHEWATCH_PUBLISH=true' <<< "$push_context"

dry_run_context="$("$context_script" workflow_dispatch main 0.0.0)"
grep -Fxq 'CACHEWATCH_RELEASE_TAG=v0.0.0' <<< "$dry_run_context"
grep -Fxq 'CACHEWATCH_PUBLISH=false' <<< "$dry_run_context"

if "$context_script" schedule main 0.0.0 >/dev/null 2>&1; then
  echo "unsupported events must fail closed" >&2
  exit 1
fi

grep -Fq 'workflow_dispatch:' "$workflow"
grep -Fq "scripts/release-context.sh \\" "$workflow"
grep -Fq "\"\$GITHUB_EVENT_NAME\" \\" "$workflow"
grep -Fq "\"\$GITHUB_REF_NAME\" \\" "$workflow"
test "$(grep -Fc "if: env.CACHEWATCH_PUBLISH == 'true'" "$workflow")" -ge 3
grep -Fq 'shasum -a 256 -c SHA256SUMS' "$workflow"

echo "Release context tests passed"
