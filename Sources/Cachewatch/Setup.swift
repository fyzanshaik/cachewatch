import Foundation
import CollectorEngine

/// `cachewatch setup`: installs the statusline forwarder and wires it into
/// ~/.claude/settings.json. Idempotent; backs up settings before changing them.
func runSetup() {
    do {
        let result = try StatuslineInstaller.install()
        print("installed \(result.scriptURL.path)")
        guard result.configurationChanged else {
            print("statusline already configured, nothing to do")
            return
        }
        if let backup = result.backupURL {
            print("backed up settings to \(backup.path)")
        }
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
