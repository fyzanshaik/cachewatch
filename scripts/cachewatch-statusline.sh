#!/bin/sh
# Cachewatch statusline forwarder.
#
# Install: set as (or in front of) your statusline command in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "/path/to/cachewatch-statusline.sh" }
# To keep an existing statusline display, export CACHEWATCH_NEXT_STATUSLINE with its command.
#
# Fire-and-forget: if Cachewatch isn't running, this is a no-op and must never
# slow a session down.

INPUT=$(cat)
SOCK="${CACHEWATCH_SOCK:-$HOME/.cachewatch/statusline.sock}"

if [ -S "$SOCK" ]; then
    printf '%s' "$INPUT" | nc -U "$SOCK" >/dev/null 2>&1 &
fi

if [ -n "$CACHEWATCH_NEXT_STATUSLINE" ]; then
    printf '%s' "$INPUT" | $CACHEWATCH_NEXT_STATUSLINE
elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '[
        .model.display_name,
        (if .context_window.used_percentage != null then "ctx \(.context_window.used_percentage | round)%" else empty end),
        (if .rate_limits.five_hour.used_percentage != null then "5h \(.rate_limits.five_hour.used_percentage | round)%" else empty end),
        (if .rate_limits.seven_day.used_percentage != null then "7d \(.rate_limits.seven_day.used_percentage | round)%" else empty end)
    ] | map(select(. != null)) | join(" | ")'
fi
