import Foundation
import CollectorEngine

func runPricingTests(_ t: TestKit) {
    let now = Date(timeIntervalSince1970: 1_784_800_000)

    func coldSession(model: String, context: Int, ttl: CacheTTL = .oneHour) -> SessionSnapshot {
        var s = SessionSnapshot(
            sessionId: "s", pid: 1, name: "s", cwd: "/tmp", status: .idle,
            startedAt: now.addingTimeInterval(-9000), updatedAt: now
        )
        s.model = model
        s.contextTokens = context
        s.cacheTTL = ttl
        s.lastTurnAt = now.addingTimeInterval(-2 * 3600)  // beyond any TTL: cold
        return s
    }

    t.run("costToResumeUsesModelRateAndTTLWriteMultiplier") { t in
        // opus 4.8: $5/MTok base; 1h TTL rewrite = 2x → 400k tokens = 400_000/1M * 5 * 2 = $4.0
        let opus = Pricing.costToResume(for: coldSession(model: "claude-opus-4-8", context: 400_000), at: now)
        t.expectEqual(opus, 4.0, "opus 1h rewrite")
        // haiku 4.5: $1/MTok; 5m TTL = 1.25x → 100k = 0.125
        let haiku = Pricing.costToResume(for: coldSession(model: "claude-haiku-4-5-20251001", context: 100_000, ttl: .fiveMinutes), at: now)
        t.expectEqual(haiku, 0.125, "haiku 5m rewrite")
    }

    t.run("costToResumeNilWhenWarmOrUnknown") { t in
        var warm = coldSession(model: "claude-opus-4-8", context: 400_000)
        warm.lastTurnAt = now.addingTimeInterval(-60)
        t.expect(Pricing.costToResume(for: warm, at: now) == nil, "warm session has no resume cost")

        var unknownModel = coldSession(model: "claude-mystery-9", context: 400_000)
        t.expect(Pricing.costToResume(for: unknownModel, at: now) == nil, "unknown model rate")
        unknownModel.model = nil
        t.expect(Pricing.costToResume(for: unknownModel, at: now) == nil, "missing model")
    }
}

func runCacheMissTests(_ t: TestKit) {
    let base = Date(timeIntervalSince1970: 1_784_810_000)

    func turn(at date: Date, read: Int, write: Int, ttl1h: Bool = true) -> AssistantTurn {
        AssistantTurn(
            sessionId: "sess-a", timestamp: date, model: "claude-opus-4-8",
            gitBranch: "main", isSidechain: false,
            usage: TurnUsage(
                inputTokens: 10, outputTokens: 5,
                cacheReadInputTokens: read, cacheCreationInputTokens: write,
                ephemeral5mTokens: ttl1h ? 0 : write, ephemeral1hTokens: ttl1h ? write : 0
            )
        )
    }

    func registryEntry() throws -> SessionRegistryEntry {
        try SessionRegistryEntry.decode(from: Data("""
        {"pid":1,"sessionId":"sess-a","cwd":"/tmp","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
        """.utf8))
    }

    t.run("fullRewriteInsideTTLIsASilentMiss") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        // 10 minutes later — 1h cache should be warm, yet the turn rewrote everything.
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(600), read: 0, write: 201_000)))
        let s = reducer.snapshot.sessions[0]
        t.expectEqual(s.lastCacheMissAt, base.addingTimeInterval(600), "miss recorded")
    }

    t.run("rewriteAfterTTLExpiryIsNotAMiss") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(2 * 3600), read: 0, write: 201_000)))
        t.expect(reducer.snapshot.sessions[0].lastCacheMissAt == nil, "expected rewrite, no miss")
    }

    t.run("normalWarmTurnIsNotAMiss") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(600), read: 201_000, write: 2000)))
        t.expect(reducer.snapshot.sessions[0].lastCacheMissAt == nil, "warm read, no miss")
    }

    t.run("cacheMissFiresAlertOncePerMiss") { t in
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(600), read: 0, write: 201_000)))
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(700), alreadyFired: fired)
        t.expectEqual(alerts.count, 1, "miss alert fires")
        t.expect(alerts[0].key.hasPrefix("miss-sess-a"), "miss key")
        fired.formUnion(alerts.map(\.key))
        t.expectEqual(AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(800), alreadyFired: fired).count, 0, "deduped")
    }

    t.run("oldAlertConfigWithoutCacheMissFieldStillDecodes") { t in
        let legacy = #"{"schemaVersion":1,"alerts":{"notificationsEnabled":true,"quota":{"enabled":true,"thresholdPercentage":80},"cacheExpiry":{"enabled":true,"warningSeconds":90,"minContextTokens":50000},"longIdle":{"enabled":true,"idleHours":6,"minContextTokens":100000,"minMemoryBytes":500000000}},"firedAlertKeys":["kept"]}"#
        let state = try AppState.decode(from: Data(legacy.utf8))
        t.expectEqual(state.firedAlertKeys, ["kept"], "fired keys preserved")
        t.expectEqual(state.alerts.cacheMiss.enabled, true, "new field defaults on")
    }
}
