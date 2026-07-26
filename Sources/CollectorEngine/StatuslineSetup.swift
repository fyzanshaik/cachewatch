import Foundation

/// Pure transform behind `cachewatch setup`: wires the forwarder into a Claude
/// Code settings.json without disturbing anything else. An existing statusline
/// is chained via CACHEWATCH_NEXT_STATUSLINE, never clobbered.
public enum StatuslineSetup {
    public struct Result {
        public let settings: Data
        public let changed: Bool
        public let chainedPrevious: String?
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

    /// Detects the forwarder without retaining or reporting the user's command.
    public static func isCachewatchConfigured(in settingsJSON: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String
        else { return false }
        return command.contains("cachewatch-statusline.sh")
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
