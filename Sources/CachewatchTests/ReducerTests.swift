import Foundation
import CollectorEngine

func runReducerTests(_ t: TestKit) {
    let base = Date(timeIntervalSince1970: 1_784_500_000)

    func registryEntry(pid: Int32 = 100, sessionId: String = "sess-a") throws -> SessionRegistryEntry {
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/tmp/project","name":"project-x1","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
        """
        return try SessionRegistryEntry.decode(from: Data(json.utf8))
    }

    func mainTurn(at date: Date, ttl1h: Int = 500, sidechain: Bool = false) -> AssistantTurn {
        AssistantTurn(
            sessionId: "sess-a",
            timestamp: date,
            model: "claude-opus-4-8",
            gitBranch: "main",
            isSidechain: sidechain,
            usage: TurnUsage(
                inputTokens: 10, outputTokens: 20,
                cacheReadInputTokens: 200_000, cacheCreationInputTokens: ttl1h,
                ephemeral5mTokens: 0, ephemeral1hTokens: ttl1h
            )
        )
    }

    t.run("registrySnapshotPopulatesFleet") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        let fleet = reducer.snapshot
        t.expectEqual(fleet.sessions.count, 1, "session count")
        t.expectEqual(fleet.sessions.first?.sessionId, "sess-a", "sessionId")
        t.expectEqual(fleet.sessions.first?.name, "project-x1", "name")
        t.expectEqual(fleet.sessions.first?.status, .idle, "status")
    }

    t.run("mainTurnEnrichesSession") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        let s = reducer.snapshot.sessions[0]
        t.expectEqual(s.model, "claude-opus-4-8", "model")
        t.expectEqual(s.gitBranch, "main", "branch")
        t.expectEqual(s.contextTokens, 200_510, "context")
        t.expectEqual(s.lastTurnAt, base, "lastTurnAt")
        t.expectEqual(s.cacheTTL, .oneHour, "ttl")
    }

    t.run("sidechainTurnDoesNotOverwriteMainContext") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        var side = mainTurn(at: base.addingTimeInterval(60), sidechain: true)
        side = AssistantTurn(
            sessionId: side.sessionId, timestamp: side.timestamp, model: "claude-haiku-4-5-20251001",
            gitBranch: side.gitBranch, isSidechain: true,
            usage: TurnUsage(inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 100,
                             cacheCreationInputTokens: 50, ephemeral5mTokens: 50, ephemeral1hTokens: 0)
        )
        reducer.apply(.assistantTurn(side))
        let s = reducer.snapshot.sessions[0]
        t.expectEqual(s.contextTokens, 200_510, "context unchanged")
        t.expectEqual(s.model, "claude-opus-4-8", "model unchanged")
        t.expectEqual(s.cacheTTL, .oneHour, "ttl unchanged")
    }

    t.run("cacheStateWarmThenCold") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        let s = reducer.snapshot.sessions[0]
        let during = s.cacheState(at: base.addingTimeInterval(30 * 60))
        t.expectEqual(during, .warm(expiresAt: base.addingTimeInterval(60 * 60)), "warm mid-TTL")
        let after = s.cacheState(at: base.addingTimeInterval(61 * 60))
        t.expectEqual(after, .cold, "cold after TTL")
    }

    t.run("cacheStateUnknownWithoutTurns") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        t.expectEqual(reducer.snapshot.sessions[0].cacheState(at: base), .unknown, "unknown")
    }

    t.run("statuslineEnrichesSessionAndGlobalRateLimits") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        let json = """
        {"session_id":"sess-a","cost":{"total_cost_usd":1.25},"context_window":{"used_percentage":63.0},"rate_limits":{"five_hour":{"used_percentage":40.0,"resets_at":"2026-07-20T10:00:00Z"},"seven_day":{"used_percentage":10.0,"resets_at":"2026-07-23T00:00:00Z"}}}
        """
        let payload = try StatuslinePayload.decode(from: Data(json.utf8))
        reducer.apply(.statusline(payload, receivedAt: base))
        let fleet = reducer.snapshot
        t.expectEqual(fleet.sessions[0].costUSD, 1.25, "cost")
        t.expectEqual(fleet.sessions[0].contextUsedPercentage, 63.0, "context %")
        t.expectEqual(fleet.rateLimits?.fiveHour?.usedPercentage, 40.0, "5h %")
        t.expectEqual(fleet.rateLimitsAsOf, base, "rate limits timestamp")
    }

    t.run("memorySampleMapsByPid") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry(pid: 4242)]))
        reducer.apply(.memorySample(pid: 4242, residentBytes: 800_000_000))
        t.expectEqual(reducer.snapshot.sessions[0].memoryBytes, 800_000_000, "memory")
    }

    t.run("sessionRemovedFromRegistryDisappearsButEnrichmentSurvivesReappearance") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        reducer.apply(.registrySnapshot([]))
        t.expectEqual(reducer.snapshot.sessions.count, 0, "gone after removal")
        reducer.apply(.registrySnapshot([try registryEntry()]))
        t.expectEqual(reducer.snapshot.sessions[0].contextTokens, 200_510, "enrichment retained")
    }

    t.run("turnForUnknownSessionIsKeptUntilRegistryCatchesUp") { t in
        var reducer = FleetReducer()
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        t.expectEqual(reducer.snapshot.sessions.count, 0, "nothing shown yet")
        reducer.apply(.registrySnapshot([try registryEntry()]))
        t.expectEqual(reducer.snapshot.sessions[0].model, "claude-opus-4-8", "turn data joined late")
    }
}
