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
}
