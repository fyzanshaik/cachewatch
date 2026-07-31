import Foundation

/// Pure transform behind `cachewatch setup`: wires the forwarder into a Claude
/// Code settings.json without disturbing anything else. An existing statusline
/// is chained via CACHEWATCH_NEXT_STATUSLINE, never clobbered.
public enum StatuslineSetup {
    public enum ConfigurationState: Sendable, Equatable {
        case configured
        case notConfigured
        case unreadable
    }

    /// Embedded so `cachewatch setup` remains self-contained in the standalone
    /// CLI binary. `SetupTests` enforces byte parity with the repository script.
    public static let forwarderScript = #"""
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
"""# + "\n"

    public struct Result {
        public let settings: Data
        public let changed: Bool
        public let chainedPrevious: String?
    }

    public static func isForwarderConfigured(in settingsJSON: Data) -> Bool {
        configurationState(in: settingsJSON) == .configured
    }

    public static func configurationState(in settingsJSON: Data) -> ConfigurationState {
        guard !settingsJSON.isEmpty else { return .notConfigured }
        guard let root = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any] else {
            return .unreadable
        }
        guard let statusLine = root["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String
        else { return .notConfigured }
        return command.contains("cachewatch-statusline.sh") ? .configured : .notConfigured
    }

    public static func apply(to settingsJSON: Data, scriptPath: String) throws -> Result {
        var root: [String: Any] = [:]
        if !settingsJSON.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any] {
            root = parsed
        }

        var statusLine = root["statusLine"] as? [String: Any] ?? [:]
        let existingCommand = statusLine["command"] as? String
        var chained: String?

        if existingCommand == scriptPath {
            let data = try serialize(root)
            return Result(settings: data, changed: false, chainedPrevious: nil)
        }

        if let existingCommand {
            var env = root["env"] as? [String: Any] ?? [:]
            env["CACHEWATCH_NEXT_STATUSLINE"] = existingCommand
            root["env"] = env
            chained = existingCommand
        }

        statusLine["type"] = "command"
        statusLine["command"] = scriptPath
        if statusLine["refreshInterval"] == nil {
            statusLine["refreshInterval"] = 60
        }
        root["statusLine"] = statusLine

        return Result(settings: try serialize(root), changed: true, chainedPrevious: chained)
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
