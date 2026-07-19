import Foundation
import CollectorEngine

func runStatusTests(_ t: TestKit) {
    let base = Date(timeIntervalSince1970: 1_784_900_000)

    func entry(status: String, statusUpdatedAt: Date) throws -> SessionRegistryEntry {
        let json = """
        {"pid":1,"sessionId":"sess-a","cwd":"/tmp/proj","name":"proj-1","status":"\(status)","startedAt":1784472863002,"updatedAt":\(Int(statusUpdatedAt.timeIntervalSince1970 * 1000)),"statusUpdatedAt":\(Int(statusUpdatedAt.timeIntervalSince1970 * 1000))}
        """
        return try SessionRegistryEntry.decode(from: Data(json.utf8))
    }

    t.run("statusUpdatedAtParsesAndFallsBackToUpdatedAt") { t in
        let e = try entry(status: "waiting", statusUpdatedAt: base)
        t.expectEqual(e.statusUpdatedAt, base, "parsed")
        let legacy = try SessionRegistryEntry.decode(from: Data("""
        {"pid":1,"sessionId":"x","cwd":"/tmp","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
        """.utf8))
        t.expectEqual(legacy.statusUpdatedAt, legacy.updatedAt, "fallback")
    }

    t.run("needsInputAlertFiresAfterThreshold") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try entry(status: "waiting", statusUpdatedAt: base)]))
        let early = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(60), alreadyFired: [])
        t.expectEqual(early.count, 0, "quiet before threshold")
        let late = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(150), alreadyFired: [])
        t.expectEqual(late.count, 1, "fires after 2min")
        t.expect(late[0].key == "input-sess-a-\(Int(base.timeIntervalSince1970))", "keyed by waiting-since")
    }

    t.run("longBusyTurnFinishedFiresOnceShortOnesQuiet") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try entry(status: "busy", statusUpdatedAt: base)]))
        // 10-minute turn ends
        reducer.apply(.registrySnapshot([try entry(status: "idle", statusUpdatedAt: base.addingTimeInterval(600))]))
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(601), alreadyFired: fired)
        t.expectEqual(alerts.count, 1, "long turn fires")
        t.expect(alerts[0].key.hasPrefix("finished-sess-a"), "finished key")
        fired.formUnion(alerts.map(\.key))
        t.expectEqual(AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(700), alreadyFired: fired).count, 0, "deduped")

        // 30-second turn ends: below the 5-minute bar
        var quick = FleetReducer()
        quick.apply(.registrySnapshot([try entry(status: "busy", statusUpdatedAt: base)]))
        quick.apply(.registrySnapshot([try entry(status: "idle", statusUpdatedAt: base.addingTimeInterval(30))]))
        t.expectEqual(AlertEngine.evaluate(fleet: quick.snapshot, config: .default, now: base.addingTimeInterval(31), alreadyFired: []).count, 0, "short turn quiet")
    }

    t.run("parsePSKeepsCommandsWithSpaces") { t in
        let ps = """
          100     1  488281 /Applications/iTerm.app/Contents/MacOS/iTerm2
          200   100  117187 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
        """
        let samples = ProcessTree.parsePS(ps)
        t.expectEqual(samples.count, 2, "rows")
        t.expectEqual(samples[1].command, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "spaces preserved")
    }

    t.run("hostAppWalksAncestryToKnownTerminal") { t in
        let table: [ProcessSample] = [
            ProcessSample(pid: 1, ppid: 0, rssBytes: 0, command: "/sbin/launchd"),
            ProcessSample(pid: 50, ppid: 1, rssBytes: 0, command: "/Applications/cmux.app/Contents/MacOS/cmux"),
            ProcessSample(pid: 60, ppid: 50, rssBytes: 0, command: "/bin/zsh"),
            ProcessSample(pid: 100, ppid: 60, rssBytes: 0, command: "claude"),
        ]
        let host = ProcessTree.hostApp(of: 100, in: table)
        t.expectEqual(host?.name, "cmux", "found host app")
        t.expectEqual(host?.pid, 50, "host pid")
        t.expect(ProcessTree.hostApp(of: 999, in: table) == nil, "unknown pid")
    }
}
