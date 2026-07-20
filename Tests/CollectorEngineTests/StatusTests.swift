import Foundation
import Testing
import CollectorEngine

@Suite
struct StatusTests {
    let base = Date(timeIntervalSince1970: 1_784_900_000)

    func entry(status: String, statusUpdatedAt: Date) throws -> SessionRegistryEntry {
        let json = """
        {"pid":1,"sessionId":"sess-a","cwd":"/tmp/proj","name":"proj-1","status":"\(status)","startedAt":1784472863002,"updatedAt":\(Int(statusUpdatedAt.timeIntervalSince1970 * 1000)),"statusUpdatedAt":\(Int(statusUpdatedAt.timeIntervalSince1970 * 1000))}
        """
        return try SessionRegistryEntry.decode(from: Data(json.utf8))
    }

    @Test
    func statusUpdatedAtParsesAndFallsBackToUpdatedAt() throws {
        let e = try entry(status: "waiting", statusUpdatedAt: base)
        #expect(e.statusUpdatedAt == base, "parsed")
        let legacy = try SessionRegistryEntry.decode(from: Data("""
        {"pid":1,"sessionId":"x","cwd":"/tmp","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
        """.utf8))
        #expect(legacy.statusUpdatedAt == legacy.updatedAt, "fallback")
    }

    @Test
    func needsInputAlertFiresAfterThreshold() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try entry(status: "waiting", statusUpdatedAt: base)]))
        let early = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(60), alreadyFired: [])
        #expect(early.count == 0, "quiet before threshold")
        let late = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(150), alreadyFired: [])
        #expect(late.count == 1, "fires after 2min")
        #expect(late[0].key == "input-sess-a-\(Int(base.timeIntervalSince1970))", "keyed by waiting-since")
    }

    @Test
    func longBusyTurnFinishedFiresOnceShortOnesQuiet() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try entry(status: "busy", statusUpdatedAt: base)]))
        // 10-minute turn ends
        reducer.apply(.registrySnapshot([try entry(status: "idle", statusUpdatedAt: base.addingTimeInterval(600))]))
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(601), alreadyFired: fired)
        #expect(alerts.count == 1, "long turn fires")
        #expect(alerts[0].key.hasPrefix("finished-sess-a"), "finished key")
        fired.formUnion(alerts.map(\.key))
        #expect(AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(700), alreadyFired: fired).count == 0, "deduped")

        // 30-second turn ends: below the 5-minute bar
        var quick = FleetReducer()
        quick.apply(.registrySnapshot([try entry(status: "busy", statusUpdatedAt: base)]))
        quick.apply(.registrySnapshot([try entry(status: "idle", statusUpdatedAt: base.addingTimeInterval(30))]))
        #expect(AlertEngine.evaluate(fleet: quick.snapshot, config: .default, now: base.addingTimeInterval(31), alreadyFired: []).count == 0, "short turn quiet")
    }

    @Test
    func parsePSKeepsCommandsWithSpaces() throws {
        let ps = """
          100     1  488281 /Applications/iTerm.app/Contents/MacOS/iTerm2
          200   100  117187 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
        """
        let samples = ProcessTree.parsePS(ps)
        #expect(samples.count == 2, "rows")
        #expect(samples[1].command == "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "spaces preserved")
    }

    @Test
    func hostAppWalksAncestryToKnownTerminal() throws {
        let table: [ProcessSample] = [
            ProcessSample(pid: 1, ppid: 0, rssBytes: 0, command: "/sbin/launchd"),
            ProcessSample(pid: 50, ppid: 1, rssBytes: 0, command: "/Applications/cmux.app/Contents/MacOS/cmux"),
            ProcessSample(pid: 60, ppid: 50, rssBytes: 0, command: "/bin/zsh"),
            ProcessSample(pid: 100, ppid: 60, rssBytes: 0, command: "claude"),
        ]
        let host = ProcessTree.hostApp(of: 100, in: table)
        #expect(host?.name == "cmux", "found host app")
        #expect(host?.pid == 50, "host pid")
        #expect(ProcessTree.hostApp(of: 999, in: table) == nil, "unknown pid")
    }
}
