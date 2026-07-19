import Foundation
import CollectorEngine

func runAlertTests(_ t: TestKit) {
    let now = Date(timeIntervalSince1970: 1_784_600_000)

    func session(
        id: String = "sess-a",
        lastTurnAt: Date? = nil,
        ttl: CacheTTL? = nil,
        contextTokens: Int? = nil,
        memoryBytes: UInt64? = nil,
        updatedAt: Date? = nil
    ) -> SessionSnapshot {
        var s = SessionSnapshot(
            sessionId: id, pid: 1, name: id, cwd: "/tmp", status: .idle,
            startedAt: now.addingTimeInterval(-86_400), updatedAt: updatedAt ?? now
        )
        s.lastTurnAt = lastTurnAt
        s.cacheTTL = ttl
        s.contextTokens = contextTokens
        s.memoryBytes = memoryBytes
        return s
    }

    func fleet(_ sessions: [SessionSnapshot] = [], fiveHourUsed: Double? = nil, resetsAt: Date? = nil) throws -> FleetSnapshot {
        var f = FleetSnapshot()
        f.sessions = sessions
        if let fiveHourUsed {
            let json = """
            {"five_hour":{"used_percentage":\(fiveHourUsed),"resets_at":"\(ISO8601DateFormatter().string(from: resetsAt ?? now.addingTimeInterval(3600)))"}}
            """
            f.rateLimits = try JSONDecoder.statusline.decode(StatuslinePayload.RateLimits.self, from: Data(json.utf8))
            f.rateLimitsAsOf = now
        }
        return f
    }

    t.run("quotaAlertFiresOnceAbove80") { t in
        let resetsAt = now.addingTimeInterval(3600)
        let f = try fleet(fiveHourUsed: 85, resetsAt: resetsAt)
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: f, config: .default, now: now, alreadyFired: fired)
        t.expectEqual(alerts.count, 1, "one alert")
        t.expect(alerts[0].key.contains("quota-5h"), "quota key")
        fired.formUnion(alerts.map(\.key))
        t.expectEqual(AlertEngine.evaluate(fleet: f, config: .default, now: now, alreadyFired: fired).count, 0, "deduped")
    }

    t.run("quotaAlertRefiresInNewWindow") { t in
        let firstWindow = try fleet(fiveHourUsed: 85, resetsAt: now.addingTimeInterval(3600))
        var fired = Set(AlertEngine.evaluate(fleet: firstWindow, config: .default, now: now, alreadyFired: []).map(\.key))
        let nextWindow = try fleet(fiveHourUsed: 85, resetsAt: now.addingTimeInterval(3600 + 18_000))
        let alerts = AlertEngine.evaluate(fleet: nextWindow, config: .default, now: now, alreadyFired: fired)
        t.expectEqual(alerts.count, 1, "new window refires")
        fired.formUnion(alerts.map(\.key))
        t.expectEqual(fired.count, 2, "distinct keys per window")
    }

    t.run("quotaBelowThresholdIsQuiet") { t in
        let f = try fleet(fiveHourUsed: 79)
        t.expectEqual(AlertEngine.evaluate(fleet: f, config: .default, now: now, alreadyFired: []).count, 0, "quiet")
    }

    t.run("cacheExpiryFiresOnlyFor5mTTLWithBigContext") { t in
        let expiring = session(lastTurnAt: now.addingTimeInterval(-4 * 60), ttl: .fiveMinutes, contextTokens: 80_000)
        let smallContext = session(id: "small", lastTurnAt: now.addingTimeInterval(-4 * 60), ttl: .fiveMinutes, contextTokens: 10_000)
        let oneHour = session(id: "hourly", lastTurnAt: now.addingTimeInterval(-59 * 60), ttl: .oneHour, contextTokens: 300_000)
        let alerts = AlertEngine.evaluate(fleet: try fleet([expiring, smallContext, oneHour]), config: .default, now: now, alreadyFired: [])
        t.expectEqual(alerts.count, 1, "only the 5m big-context session")
        t.expect(alerts[0].key.contains("cache-sess-a"), "keyed by session")
    }

    t.run("cacheExpiryRearmsAfterNewTurn") { t in
        let turn1 = now.addingTimeInterval(-4 * 60)
        let s1 = session(lastTurnAt: turn1, ttl: .fiveMinutes, contextTokens: 80_000)
        var fired = Set(AlertEngine.evaluate(fleet: try fleet([s1]), config: .default, now: now, alreadyFired: []).map(\.key))
        t.expectEqual(fired.count, 1, "fired once")

        let later = now.addingTimeInterval(10 * 60)
        let s2 = session(lastTurnAt: later.addingTimeInterval(-4 * 60), ttl: .fiveMinutes, contextTokens: 80_000)
        let alerts = AlertEngine.evaluate(fleet: try fleet([s2]), config: .default, now: later, alreadyFired: fired)
        t.expectEqual(alerts.count, 1, "new turn re-arms the alert")
    }

    t.run("longIdleFiresOnceForHeavyStaleSession") { t in
        let stale = session(
            lastTurnAt: now.addingTimeInterval(-7 * 3600), ttl: .oneHour,
            contextTokens: 200_000, memoryBytes: 900_000_000,
            updatedAt: now.addingTimeInterval(-7 * 3600)
        )
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: try fleet([stale]), config: .default, now: now, alreadyFired: fired)
        t.expectEqual(alerts.count, 1, "long idle fires")
        t.expect(alerts[0].key == "idle-sess-a", "idle key is per-session, no timestamp")
        fired.formUnion(alerts.map(\.key))
        let muchLater = now.addingTimeInterval(24 * 3600)
        t.expectEqual(AlertEngine.evaluate(fleet: try fleet([stale]), config: .default, now: muchLater, alreadyFired: fired).count, 0, "never refires")
    }

    t.run("disabledAlertsStayQuiet") { t in
        var config = AlertConfig.default
        config.quota.enabled = false
        let f = try fleet(fiveHourUsed: 95)
        t.expectEqual(AlertEngine.evaluate(fleet: f, config: config, now: now, alreadyFired: []).count, 0, "disabled")
    }

    t.run("stateRoundTripsAndDefaultsOnMissingFields") { t in
        var state = AppState()
        state.firedAlertKeys = ["a", "b"]
        state.alerts.longIdle.idleHours = 12
        let data = try state.encoded()
        let decoded = try AppState.decode(from: data)
        t.expectEqual(decoded.firedAlertKeys, ["a", "b"], "fired keys")
        t.expectEqual(decoded.alerts.longIdle.idleHours, 12, "custom threshold")

        let minimal = try AppState.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        t.expectEqual(minimal.alerts.quota.thresholdPercentage, 80, "defaults applied")
    }
}
