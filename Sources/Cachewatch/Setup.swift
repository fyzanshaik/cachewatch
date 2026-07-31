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
        try Data(StatuslineSetup.forwarderScript.utf8).write(
            to: URL(fileURLWithPath: scriptPath),
            options: .atomic
        )
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
