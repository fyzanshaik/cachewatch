import Foundation
import Testing
import CollectorEngine
import CachewatchTerminal

@Suite
struct TerminalTests {
    let now = Date(timeIntervalSince1970: 1_784_900_000)

    @Test
    func rendersEmptyFleet() {
        let output = TerminalFleetRenderer.render(FleetSnapshot(), now: now)
        #expect(output.contains("CACHEWATCH"))
        #expect(output.contains("No live Claude Code or Codex sessions."))
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
        session.contextUsedPercentage = 62.5
        session.lastTurnAt = now.addingTimeInterval(-120)
        session.cacheTTL = .fiveMinutes
        session.memoryBytes = 512_000_000

        var codex = SessionSnapshot(
            sessionId: "codex-1234",
            pid: 43,
            provider: .codex,
            name: "codex-project",
            cwd: "/tmp/codex-project",
            status: .busy,
            startedAt: now.addingTimeInterval(-600),
            updatedAt: now
        )
        codex.model = "gpt-5.6-sol"
        codex.contextTokens = 80_000
        codex.contextUsedPercentage = 31

        var fleet = FleetSnapshot()
        fleet.sessions = [session, codex]
        let limits = try JSONDecoder.statusline.decode(
            StatuslinePayload.RateLimits.self,
            from: Data(#"{"five_hour":{"used_percentage":43,"resets_at":1784903600}}"#.utf8)
        )
        fleet.rateLimits = limits
        fleet.codexRateLimits = StatuslinePayload.RateLimits(
            fiveHour: nil,
            sevenDay: StatuslinePayload.RateLimitWindow(
                usedPercentage: 5,
                resetsAt: now.addingTimeInterval(86_400)
            )
        )

        let output = TerminalFleetRenderer.render(fleet, now: now)
        #expect(output.contains("CACHEWATCH"))
        #expect(output.contains("2 sessions"))
        #expect(output.contains("1 busy"))
        #expect(output.contains("1 waiting"))
        #expect(output.contains("Claude"))
        #expect(output.contains("5h"))
        #expect(output.contains("[█████░░░░░░░] 43%"))
        #expect(output.contains("Codex"))
        #expect(output.contains("7d"))
        #expect(output.contains("AGENT"))
        #expect(output.contains("CLAUDE"))
        #expect(output.contains("CODEX"))
        #expect(output.contains("SESSION"))
        #expect(output.contains("cachewatch"))
        #expect(output.contains("codex-project"))
        #expect(output.contains("WAITING"))
        #expect(output.contains("opus-4-1"))
        #expect(output.contains("[█████░░░] 62% · 125k"))
        #expect(output.contains("warm 3:00"))
        #expect(output.contains("512 MB"))
        #expect(output.contains("2m ago"))

        let ansi = TerminalFleetRenderer.render(fleet, now: now, style: .ansi, live: true)
        #expect(ansi.contains("\u{001B}["))
        #expect(ansi.contains("LIVE"))
        #expect(ansi.contains("Ctrl-C to stop"))
    }

    @Test
    func encodesStableFleetJSONForDesktopFrontends() throws {
        var session = SessionSnapshot(
            sessionId: "codex-1234",
            pid: 43,
            provider: .codex,
            name: "cachewatch",
            cwd: "/tmp/cachewatch",
            status: .busy,
            startedAt: now.addingTimeInterval(-600),
            updatedAt: now
        )
        session.model = "gpt-5.6-sol"
        session.gitBranch = "agent/codex-linux-support"
        session.contextTokens = 80_000
        session.contextUsedPercentage = 31
        session.lastTurnAt = now.addingTimeInterval(-45)
        session.memoryBytes = 766_000_000

        var claude = SessionSnapshot(
            sessionId: "claude-1234",
            pid: 44,
            name: "api",
            cwd: "/tmp/api",
            status: .waiting,
            startedAt: now.addingTimeInterval(-1_200),
            updatedAt: now
        )
        claude.lastTurnAt = now.addingTimeInterval(-120)
        claude.cacheTTL = .fiveMinutes

        var fleet = FleetSnapshot()
        fleet.sessions = [session, claude]
        fleet.rateLimits = StatuslinePayload.RateLimits(
            fiveHour: StatuslinePayload.RateLimitWindow(
                usedPercentage: 43,
                resetsAt: now.addingTimeInterval(3_600)
            ),
            sevenDay: nil
        )
        fleet.codexRateLimits = StatuslinePayload.RateLimits(
            fiveHour: nil,
            sevenDay: StatuslinePayload.RateLimitWindow(
                usedPercentage: 5,
                resetsAt: now.addingTimeInterval(86_400)
            )
        )

        let data = try TerminalFleetJSON.encode(fleet, now: now)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["generatedAt"] as? Double == now.timeIntervalSince1970)

        let summary = try #require(object["summary"] as? [String: Int])
        #expect(summary == ["total": 2, "busy": 1, "idle": 0, "waiting": 1])

        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)
        #expect(sessions[0]["id"] as? String == "codex-1234")
        #expect(sessions[0]["provider"] as? String == "codex")
        #expect(sessions[0]["status"] as? String == "busy")
        #expect(sessions[0]["contextTokens"] as? Int == 80_000)
        #expect(sessions[0]["memoryBytes"] as? Int == 766_000_000)
        #expect(sessions[0]["cacheState"] as? String == "unknown")
        #expect(sessions[1]["cacheState"] as? String == "warm")
        #expect(sessions[1]["cacheExpiresAt"] as? Double == now.addingTimeInterval(180).timeIntervalSince1970)

        let quotas = try #require(object["quotas"] as? [[String: Any]])
        #expect(quotas.count == 2)
        #expect(quotas[0]["provider"] as? String == "claude")
        #expect(quotas[0]["window"] as? String == "5h")
        #expect(quotas[0]["usedPercentage"] as? Double == 43)
        #expect(quotas[1]["provider"] as? String == "codex")
        #expect(quotas[1]["window"] as? String == "7d")

        #expect(!data.contains(0x0A))
    }
}
