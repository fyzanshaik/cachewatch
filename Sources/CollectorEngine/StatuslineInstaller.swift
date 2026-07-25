import Foundation

public struct StatuslineInstallResult: Sendable, Equatable {
    public let scriptURL: URL
    public let settingsURL: URL
    public let backupURL: URL?
    public let configurationChanged: Bool
    public let chainedPrevious: String?

    public init(
        scriptURL: URL,
        settingsURL: URL,
        backupURL: URL?,
        configurationChanged: Bool,
        chainedPrevious: String?
    ) {
        self.scriptURL = scriptURL
        self.settingsURL = settingsURL
        self.backupURL = backupURL
        self.configurationChanged = configurationChanged
        self.chainedPrevious = chainedPrevious
    }
}

/// Filesystem operation behind `cachewatch setup`, shared by the macOS and
/// Linux frontends. The script is always refreshed; settings are only rewritten
/// when the configured command changes.
public enum StatuslineInstaller {
    public static func install(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) throws -> StatuslineInstallResult {
        let fileManager = FileManager.default
        let scriptDirectory = homeDirectory.appending(path: ".cachewatch")
        let scriptURL = scriptDirectory.appending(path: "cachewatch-statusline.sh")
        let claudeDirectory = homeDirectory.appending(path: ".claude")
        let settingsURL = claudeDirectory.appending(path: "settings.json")

        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try Data(forwarderScript.utf8).write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let existing = (try? Data(contentsOf: settingsURL)) ?? Data()
        let setup = try StatuslineSetup.apply(
            to: existing,
            scriptPath: "~/.cachewatch/cachewatch-statusline.sh"
        )
        guard setup.changed else {
            return StatuslineInstallResult(
                scriptURL: scriptURL,
                settingsURL: settingsURL,
                backupURL: nil,
                configurationChanged: false,
                chainedPrevious: nil
            )
        }

        var backupURL: URL?
        if !existing.isEmpty {
            let backup = claudeDirectory.appending(
                path: "settings.json.bak-cachewatch-\(Int(now.timeIntervalSince1970))"
            )
            try existing.write(to: backup)
            backupURL = backup
        }
        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try setup.settings.write(to: settingsURL, options: .atomic)
        return StatuslineInstallResult(
            scriptURL: scriptURL,
            settingsURL: settingsURL,
            backupURL: backupURL,
            configurationChanged: true,
            chainedPrevious: setup.chainedPrevious
        )
    }

    /// Kept in sync with scripts/cachewatch-statusline.sh so setup works from
    /// a git clone, Homebrew installation, or standalone binary.
    private static let forwarderScript = #"""
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
}
