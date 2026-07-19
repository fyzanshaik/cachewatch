import Foundation
import CollectorEngine

func runSetupTests(_ t: TestKit) {
    let script = "/Users/dev/.cachewatch/cachewatch-statusline.sh"

    func dict(_ data: Data) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: data) as! NSDictionary
    }

    t.run("addsStatuslineToFreshSettings") { t in
        let input = Data(#"{"model":"claude-fable-5"}"#.utf8)
        let result = try StatuslineSetup.apply(to: input, scriptPath: script)
        t.expectEqual(result.changed, true, "changed")
        let d = try dict(result.settings)
        let sl = d["statusLine"] as! NSDictionary
        t.expectEqual(sl["command"] as? String, script, "command")
        t.expectEqual(sl["refreshInterval"] as? Int, 60, "refresh")
        t.expectEqual(d["model"] as? String, "claude-fable-5", "other keys preserved")
    }

    t.run("chainsExistingStatuslineViaEnv") { t in
        let input = Data(#"{"statusLine":{"type":"command","command":"~/bin/my-statusline.sh","refreshInterval":30}}"#.utf8)
        let result = try StatuslineSetup.apply(to: input, scriptPath: script)
        let d = try dict(result.settings)
        let sl = d["statusLine"] as! NSDictionary
        t.expectEqual(sl["command"] as? String, script, "ours installed")
        t.expectEqual(sl["refreshInterval"] as? Int, 30, "existing interval kept")
        let env = d["env"] as! NSDictionary
        t.expectEqual(env["CACHEWATCH_NEXT_STATUSLINE"] as? String, "~/bin/my-statusline.sh", "previous chained")
        t.expectEqual(result.chainedPrevious, "~/bin/my-statusline.sh", "reported")
    }

    t.run("isIdempotent") { t in
        let input = Data(#"{"model":"m"}"#.utf8)
        let once = try StatuslineSetup.apply(to: input, scriptPath: script)
        let twice = try StatuslineSetup.apply(to: once.settings, scriptPath: script)
        t.expectEqual(twice.changed, false, "second run is a no-op")
        t.expectEqual(try dict(twice.settings), try dict(once.settings), "settings identical")
    }

    t.run("emptyOrMissingFileStartsFresh") { t in
        let result = try StatuslineSetup.apply(to: Data(), scriptPath: script)
        t.expectEqual(result.changed, true, "created")
        let d = try dict(result.settings)
        t.expect(d["statusLine"] != nil, "statusLine present")
    }
}
