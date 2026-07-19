import Foundation
import CollectorEngine

/// `cachewatch setup`: installs the statusline forwarder and wires it into
/// ~/.claude/settings.json. Idempotent; backs up settings before changing them.
func runSetup() {
    let home = NSHomeDirectory()
    let scriptDir = "\(home)/.cachewatch"
    let scriptPath = "\(scriptDir)/cachewatch-statusline.sh"
    let settingsPath = "\(home)/.claude/settings.json"
    let fm = FileManager.default

    do {
        try fm.createDirectory(atPath: scriptDir, withIntermediateDirectories: true)
        try Data(forwarderScript.utf8).write(to: URL(fileURLWithPath: scriptPath), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        print("installed \(scriptPath)")

        let existing = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath))) ?? Data()
        let result = try StatuslineSetup.apply(to: existing, scriptPath: "~/.cachewatch/cachewatch-statusline.sh")
        guard result.changed else {
            print("statusline already configured, nothing to do")
            return
        }
        if !existing.isEmpty {
            let backup = "\(settingsPath).bak-cachewatch-\(Int(Date().timeIntervalSince1970))"
            try existing.write(to: URL(fileURLWithPath: backup))
            print("backed up settings to \(backup)")
        }
        try fm.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        try result.settings.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        print("statusline configured in ~/.claude/settings.json")
        if let previous = result.chainedPrevious {
            print("your previous statusline (\(previous)) is chained and keeps rendering")
        }
        print("new Claude Code sessions pick this up on start; run `swift run Cachewatch` (or `cachewatch`) for the menu bar app")
    } catch {
        print("setup failed: \(error.localizedDescription)")
        exit(1)
    }
}

/// Kept in sync with scripts/cachewatch-statusline.sh so `setup` works from any
/// install location (brew, git clone, bare binary).
private let forwarderScript = #"""
#!/bin/sh
# Cachewatch statusline forwarder (installed by `cachewatch setup`).
#
# Renders a compact statusline and forwards the JSON to Cachewatch's socket.
# If Cachewatch isn't running the forward is a no-op. To chain another
# statusline display, set CACHEWATCH_NEXT_STATUSLINE to its command.

INPUT=$(cat)
SOCK="${CACHEWATCH_SOCK:-$HOME/.cachewatch/statusline.sock}"

# Foreground on purpose: Claude Code kills the script's process group on exit,
# reaping backgrounded children before they deliver. The listener closes the
# connection as soon as it decodes the JSON, so this returns in milliseconds;
# -w 1 bounds the cost if the listener is wedged.
if [ -S "$SOCK" ]; then
    printf '%s' "$INPUT" | nc -U -w 1 "$SOCK" >/dev/null 2>&1
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
"""#
