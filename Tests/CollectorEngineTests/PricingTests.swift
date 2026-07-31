import Foundation
import Testing
import CollectorEngine

@Suite
struct PricingTests {
    let now = Date(timeIntervalSince1970: 1_784_800_000)
    let sonnet5StandardPricingStarts = Date(timeIntervalSince1970: 1_788_220_800)

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

    @Test
    func sonnet5PriceChangesAtSeptember2026UTCBoundary() {
        #expect(Pricing.baseInputRate(
            model: "claude-sonnet-5",
            at: sonnet5StandardPricingStarts.addingTimeInterval(-1)
        ) == 2.0)
        #expect(Pricing.baseInputRate(
            model: "claude-sonnet-5",
            at: sonnet5StandardPricingStarts
        ) == 3.0)
    }

    @Test
    func turnCostUsesTheRateEffectiveAtTheTurnTimestamp() {
        let usage = TurnUsage(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            ephemeral5mTokens: 0,
            ephemeral1hTokens: 0
        )

        #expect(Pricing.turnCostUSD(
            model: "claude-sonnet-5", usage: usage,
            at: sonnet5StandardPricingStarts.addingTimeInterval(-1)
        ) == 2.0)
        #expect(Pricing.turnCostUSD(
            model: "claude-sonnet-5", usage: usage,
            at: sonnet5StandardPricingStarts
        ) == 3.0)
    }

    @Test
    func mostSpecificModelPriceWins() {
        #expect(Pricing.baseInputRate(model: "claude-opus-5", at: now) == 5.0)
        #expect(Pricing.baseInputRate(model: "claude-opus-4-1", at: now) == 15.0)
        #expect(Pricing.baseInputRate(model: "claude-opus-4-8", at: now) == 5.0)
        #expect(Pricing.baseInputRate(model: "claude-mystery-9", at: now) == nil)
    }

    @Test
    func resumeEstimateExposesItsEffectivePriceBasis() throws {
        let estimate = try #require(Pricing.resumeEstimate(
            for: coldSession(
                model: "claude-sonnet-5",
                context: 200_000,
                ttl: .fiveMinutes
            ),
            at: now
        ))

        #expect(estimate.costUSD == 0.5)
        #expect(estimate.price.inputPerMTok == 2.0)
        #expect(estimate.writeMultiplier == 1.25)
        #expect(estimate.price.sourceURL == Pricing.sourceURL)
    }

    @Test
    func coldResumeUsesTheRateEffectiveWhenTheEstimateIsMade() {
        let session = coldSession(
            model: "claude-sonnet-5",
            context: 200_000,
            ttl: .fiveMinutes
        )

        #expect(Pricing.costToResume(
            for: session,
            at: sonnet5StandardPricingStarts.addingTimeInterval(-1)
        ) == 0.5)
        let postBoundary = Pricing.costToResume(
            for: session,
            at: sonnet5StandardPricingStarts
        )
        #expect(postBoundary.map { abs($0 - 0.75) < 0.000_001 } == true)
    }

    @Test
    func reducerPricesReplayedTurnsAtTheirOwnTimestamps() {
        let usage = TurnUsage(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            ephemeral5mTokens: 0,
            ephemeral1hTokens: 0
        )
        var reducer = FleetReducer()
        reducer.apply(.assistantTurn(AssistantTurn(
            sessionId: "before", timestamp: sonnet5StandardPricingStarts.addingTimeInterval(-1),
            model: "claude-sonnet-5", gitBranch: nil, isSidechain: false, usage: usage
        )))
        reducer.apply(.assistantTurn(AssistantTurn(
            sessionId: "after", timestamp: sonnet5StandardPricingStarts,
            model: "claude-sonnet-5", gitBranch: nil, isSidechain: false, usage: usage
        )))

        #expect(reducer.snapshot.cumulativeTurnCostUSD == 5.0)
    }

    @Test
    func costToResumeUsesModelRateAndTTLWriteMultiplier() throws {
        // opus 4.8: $5/MTok base; 1h TTL rewrite = 2x → 400k tokens = 400_000/1M * 5 * 2 = $4.0
        let opus = Pricing.costToResume(for: coldSession(model: "claude-opus-4-8", context: 400_000), at: now)
        #expect(opus == 4.0, "opus 1h rewrite")
        // haiku 4.5: $1/MTok; 5m TTL = 1.25x → 100k = 0.125
        let haiku = Pricing.costToResume(for: coldSession(model: "claude-haiku-4-5-20251001", context: 100_000, ttl: .fiveMinutes), at: now)
        #expect(haiku == 0.125, "haiku 5m rewrite")
    }

    @Test
    func costToResumeNilWhenWarmOrUnknown() throws {
        var warm = coldSession(model: "claude-opus-4-8", context: 400_000)
        warm.lastTurnAt = now.addingTimeInterval(-60)
        #expect(Pricing.costToResume(for: warm, at: now) == nil, "warm session has no resume cost")

        var unknownModel = coldSession(model: "claude-mystery-9", context: 400_000)
        #expect(Pricing.costToResume(for: unknownModel, at: now) == nil, "unknown model rate")
        unknownModel.model = nil
        #expect(Pricing.costToResume(for: unknownModel, at: now) == nil, "missing model")
    }
}

@Suite
struct CacheMissTests {
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

    @Test
    func fullRewriteInsideTTLIsASilentMiss() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        // 10 minutes later — 1h cache should be warm, yet the turn rewrote everything.
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(600), read: 0, write: 201_000)))
        let s = reducer.snapshot.sessions[0]
        #expect(s.lastCacheMissAt == base.addingTimeInterval(600), "miss recorded")
    }

    @Test
    func rewriteAfterTTLExpiryIsNotAMiss() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(2 * 3600), read: 0, write: 201_000)))
        #expect(reducer.snapshot.sessions[0].lastCacheMissAt == nil, "expected rewrite, no miss")
    }

    @Test
    func normalWarmTurnIsNotAMiss() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(600), read: 201_000, write: 2000)))
        #expect(reducer.snapshot.sessions[0].lastCacheMissAt == nil, "warm read, no miss")
    }

    @Test
    func cacheMissFiresAlertOncePerMiss() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(turn(at: base, read: 200_000, write: 1000)))
        reducer.apply(.assistantTurn(turn(at: base.addingTimeInterval(600), read: 0, write: 201_000)))
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(700), alreadyFired: fired)
        #expect(alerts.count == 1, "miss alert fires")
        #expect(alerts[0].key.hasPrefix("miss-sess-a"), "miss key")
        fired.formUnion(alerts.map(\.key))
        #expect(AlertEngine.evaluate(fleet: reducer.snapshot, config: .default, now: base.addingTimeInterval(800), alreadyFired: fired).count == 0, "deduped")
    }

    @Test
    func oldAlertConfigWithoutCacheMissFieldStillDecodes() throws {
        let legacy = #"{"schemaVersion":1,"alerts":{"notificationsEnabled":true,"quota":{"enabled":true,"thresholdPercentage":80},"cacheExpiry":{"enabled":true,"warningSeconds":90,"minContextTokens":50000},"longIdle":{"enabled":true,"idleHours":6,"minContextTokens":100000,"minMemoryBytes":500000000}},"firedAlertKeys":["kept"]}"#
        let state = try AppState.decode(from: Data(legacy.utf8))
        #expect(state.firedAlertKeys == ["kept"], "fired keys preserved")
        #expect(state.alerts.cacheMiss.enabled == true, "new field defaults on")
    }
}
