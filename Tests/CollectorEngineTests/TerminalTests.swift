import Foundation
import Testing
import CollectorEngine
import CachewatchTerminal

@Suite
struct TerminalTests {
    let now = Date(timeIntervalSince1970: 1_784_900_000)

    @Test
    func rendersEmptyFleet() {
        #expect(TerminalFleetRenderer.render(FleetSnapshot(), now: now) == "No live Claude Code sessions.")
    }

    @Test
    func rendersSessionTableAndQuota() throws {
        var session = SessionSnapshot(
            sessionId: "session-1234",
            pid: 42,
            name: "cachewatch",
            cwd: "/tmp/cachewatch",
            status: .waiting,
            startedAt: now.addingTimeInterval(-3_600),
            updatedAt: now
        )
        session.model = "claude-opus-4-1"
        session.contextTokens = 125_000
        session.lastTurnAt = now.addingTimeInterval(-120)
        session.cacheTTL = .fiveMinutes
        session.memoryBytes = 512_000_000

        var fleet = FleetSnapshot()
        fleet.sessions = [session]
        let limits = try JSONDecoder.statusline.decode(
            StatuslinePayload.RateLimits.self,
            from: Data(#"{"five_hour":{"used_percentage":43,"resets_at":1784903600}}"#.utf8)
        )
        fleet.rateLimits = limits

        let output = TerminalFleetRenderer.render(fleet, now: now)
        #expect(output.contains("Quota: 5h 43%"))
        #expect(output.contains("SESSION"))
        #expect(output.contains("cachewatch"))
        #expect(output.contains("waiting"))
        #expect(output.contains("opus-4-1"))
        #expect(output.contains("125k"))
        #expect(output.contains("warm 3:00"))
        #expect(output.contains("512 MB"))
        #expect(output.contains("2m ago"))
    }
}
