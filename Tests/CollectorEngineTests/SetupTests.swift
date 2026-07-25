import Foundation
import Testing
import CollectorEngine

@Suite
struct SetupTests {
    let script = "/Users/dev/.cachewatch/cachewatch-statusline.sh"

    func dict(_ data: Data) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: data) as! NSDictionary
    }

    @Test
    func addsStatuslineToFreshSettings() throws {
        let input = Data(#"{"model":"claude-fable-5"}"#.utf8)
        let result = try StatuslineSetup.apply(to: input, scriptPath: script)
        #expect(result.changed == true, "changed")
        let settings = try dict(result.settings)
        let statusLine = settings["statusLine"] as! NSDictionary
        #expect(statusLine["command"] as? String == script, "command")
        #expect(statusLine["refreshInterval"] as? Int == 60, "refresh")
        #expect(settings["model"] as? String == "claude-fable-5", "other keys preserved")
    }

    @Test
    func chainsExistingStatuslineViaEnv() throws {
        let input = Data(#"{"statusLine":{"type":"command","command":"~/bin/my-statusline.sh","refreshInterval":30}}"#.utf8)
        let result = try StatuslineSetup.apply(to: input, scriptPath: script)
        let settings = try dict(result.settings)
        let statusLine = settings["statusLine"] as! NSDictionary
        #expect(statusLine["command"] as? String == script, "ours installed")
        #expect(statusLine["refreshInterval"] as? Int == 30, "existing interval kept")
        let environment = settings["env"] as! NSDictionary
        #expect(environment["CACHEWATCH_NEXT_STATUSLINE"] as? String == "~/bin/my-statusline.sh", "previous chained")
        #expect(result.chainedPrevious == "~/bin/my-statusline.sh", "reported")
    }

    @Test
    func isIdempotent() throws {
        let input = Data(#"{"model":"m"}"#.utf8)
        let once = try StatuslineSetup.apply(to: input, scriptPath: script)
        let twice = try StatuslineSetup.apply(to: once.settings, scriptPath: script)
        #expect(twice.changed == false, "second run is a no-op")
        let twiceDictionary = try dict(twice.settings)
        let onceDictionary = try dict(once.settings)
        #expect(twiceDictionary == onceDictionary, "settings identical")
    }

    @Test
    func emptyOrMissingFileStartsFresh() throws {
        let result = try StatuslineSetup.apply(to: Data(), scriptPath: script)
        #expect(result.changed == true, "created")
        let settings = try dict(result.settings)
        #expect(settings["statusLine"] != nil, "statusLine present")
    }

    @Test
    func installerWritesExecutableScriptBacksUpSettingsAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "cw-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDirectory = home.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settings = claudeDirectory.appending(path: "settings.json")
        let existing = Data(#"{"model":"claude-fable-5"}"#.utf8)
        try existing.write(to: settings)

        let now = Date(timeIntervalSince1970: 1_784_900_000)
        let first = try StatuslineInstaller.install(homeDirectory: home, now: now)
        #expect(first.configurationChanged)
        let backupURL = try #require(first.backupURL)
        #expect(backupURL.lastPathComponent == "settings.json.bak-cachewatch-1784900000")
        #expect(try Data(contentsOf: backupURL) == existing)

        let scriptData = try Data(contentsOf: first.scriptURL)
        #expect(String(decoding: scriptData, as: UTF8.self).contains("nc -U -w 1"))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.scriptURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o755)

        let configured = try dict(Data(contentsOf: first.settingsURL))
        let statusLine = try #require(configured["statusLine"] as? NSDictionary)
        #expect(statusLine["command"] as? String == "~/.cachewatch/cachewatch-statusline.sh")

        let second = try StatuslineInstaller.install(homeDirectory: home, now: now.addingTimeInterval(1))
        #expect(!second.configurationChanged)
        #expect(second.backupURL == nil)
    }
}
