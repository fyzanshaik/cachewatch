import Foundation
import Testing
import CollectorEngine

@Suite
struct AlertTests {
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

    @Test
    func quotaAlertFiresOnceAbove80() throws {
        let resetsAt = now.addingTimeInterval(3600)
        let f = try fleet(fiveHourUsed: 85, resetsAt: resetsAt)
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: f, config: .default, now: now, alreadyFired: fired)
        #expect(alerts.count == 1, "one alert")
        #expect(alerts[0].key.contains("quota-5h"), "quota key")
        fired.formUnion(alerts.map(\.key))
        #expect(AlertEngine.evaluate(fleet: f, config: .default, now: now, alreadyFired: fired).count == 0, "deduped")
    }

    @Test
    func quotaAlertRefiresInNewWindow() throws {
        let firstWindow = try fleet(fiveHourUsed: 85, resetsAt: now.addingTimeInterval(3600))
        var fired = Set(AlertEngine.evaluate(fleet: firstWindow, config: .default, now: now, alreadyFired: []).map(\.key))
        let nextWindow = try fleet(fiveHourUsed: 85, resetsAt: now.addingTimeInterval(3600 + 18_000))
        let alerts = AlertEngine.evaluate(fleet: nextWindow, config: .default, now: now, alreadyFired: fired)
        #expect(alerts.count == 1, "new window refires")
        fired.formUnion(alerts.map(\.key))
        #expect(fired.count == 2, "distinct keys per window")
    }

    @Test
    func quotaBelowThresholdIsQuiet() throws {
        let f = try fleet(fiveHourUsed: 79)
        #expect(AlertEngine.evaluate(fleet: f, config: .default, now: now, alreadyFired: []).count == 0, "quiet")
    }

    @Test
    func cacheExpiryFiresOnlyFor5mTTLWithBigContext() throws {
        let expiring = session(lastTurnAt: now.addingTimeInterval(-4 * 60), ttl: .fiveMinutes, contextTokens: 80_000)
        let smallContext = session(id: "small", lastTurnAt: now.addingTimeInterval(-4 * 60), ttl: .fiveMinutes, contextTokens: 10_000)
        let oneHour = session(id: "hourly", lastTurnAt: now.addingTimeInterval(-59 * 60), ttl: .oneHour, contextTokens: 300_000)
        let alerts = AlertEngine.evaluate(fleet: try fleet([expiring, smallContext, oneHour]), config: .default, now: now, alreadyFired: [])
        #expect(alerts.count == 1, "only the 5m big-context session")
        #expect(alerts[0].key.contains("cache-sess-a"), "keyed by session")
    }

    @Test
    func cacheExpiryRearmsAfterNewTurn() throws {
        let turn1 = now.addingTimeInterval(-4 * 60)
        let s1 = session(lastTurnAt: turn1, ttl: .fiveMinutes, contextTokens: 80_000)
        let fired = Set(AlertEngine.evaluate(fleet: try fleet([s1]), config: .default, now: now, alreadyFired: []).map(\.key))
        #expect(fired.count == 1, "fired once")

        let later = now.addingTimeInterval(10 * 60)
        let s2 = session(lastTurnAt: later.addingTimeInterval(-4 * 60), ttl: .fiveMinutes, contextTokens: 80_000)
        let alerts = AlertEngine.evaluate(fleet: try fleet([s2]), config: .default, now: later, alreadyFired: fired)
        #expect(alerts.count == 1, "new turn re-arms the alert")
    }

    @Test
    func longIdleFiresOnceForHeavyStaleSession() throws {
        let stale = session(
            lastTurnAt: now.addingTimeInterval(-7 * 3600), ttl: .oneHour,
            contextTokens: 200_000, memoryBytes: 900_000_000,
            updatedAt: now.addingTimeInterval(-7 * 3600)
        )
        var fired: Set<String> = []
        let alerts = AlertEngine.evaluate(fleet: try fleet([stale]), config: .default, now: now, alreadyFired: fired)
        #expect(alerts.count == 1, "long idle fires")
        #expect(alerts[0].key == "idle-sess-a", "idle key is per-session, no timestamp")
        fired.formUnion(alerts.map(\.key))
        let muchLater = now.addingTimeInterval(24 * 3600)
        #expect(AlertEngine.evaluate(fleet: try fleet([stale]), config: .default, now: muchLater, alreadyFired: fired).count == 0, "never refires")
    }

    @Test
    func disabledAlertsStayQuiet() throws {
        var config = AlertConfig.default
        config.quota.enabled = false
        let f = try fleet(fiveHourUsed: 95)
        #expect(AlertEngine.evaluate(fleet: f, config: config, now: now, alreadyFired: []).count == 0, "disabled")
    }

    @Test
    func stateRoundTripsAndDefaultsOnMissingFields() throws {
        var state = AppState()
        state.firedAlertKeys = ["a", "b"]
        state.alerts.longIdle.idleHours = 12
        let data = try state.encoded()
        let decoded = try AppState.decode(from: data)
        #expect(decoded.firedAlertKeys == ["a", "b"], "fired keys")
        #expect(decoded.alerts.longIdle.idleHours == 12, "custom threshold")

        let minimal = try AppState.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(minimal.alerts.quota.thresholdPercentage == 80, "defaults applied")
    }

    @Test
    func launchAtLoginPersistsAndDefaultsOff() throws {
        var state = AppState()
        #expect(state.launchAtLogin == false, "default")

        state.launchAtLogin = true
        let decoded = try AppState.decode(from: state.encoded())
        #expect(decoded.launchAtLogin == true, "round trip")

        let legacy = try AppState.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(legacy.launchAtLogin == false, "missing legacy field")
    }

    @Test
    func launchAtLoginStatusHasConsistentCapabilities() throws {
        #expect(LaunchAtLoginStatus.unavailable.canManage == false, "unavailable is disabled")
        #expect(LaunchAtLoginStatus.disabled.isRegistered == false, "disabled is not registered")
        #expect(LaunchAtLoginStatus.disabled.canManage == true, "bundled disabled state is manageable")
        #expect(LaunchAtLoginStatus.enabled.isRegistered == true, "enabled is registered")
        #expect(LaunchAtLoginStatus.pendingApproval.isRegistered == true, "pending remains registered")
    }
}
