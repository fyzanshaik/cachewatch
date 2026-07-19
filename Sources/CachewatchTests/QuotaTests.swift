import Foundation
import CollectorEngine

func runQuotaTests(_ t: TestKit) {
    let now = Date(timeIntervalSince1970: 1_784_700_000)

    func window(used: Double, resetsIn: TimeInterval) throws -> StatuslinePayload.RateLimitWindow {
        let json = """
        {"used_percentage":\(used),"resets_at":\(now.timeIntervalSince1970 + resetsIn)}
        """
        return try JSONDecoder.statusline.decode(StatuslinePayload.RateLimitWindow.self, from: Data(json.utf8))
    }

    t.run("windowIsCurrentBeforeResetAndExpiredAfter") { t in
        let w = try window(used: 68, resetsIn: 1800)
        t.expectEqual(w.isExpired(at: now), false, "current before reset")
        t.expectEqual(w.isExpired(at: now.addingTimeInterval(1801)), true, "expired after reset")
        let noReset = try JSONDecoder.statusline.decode(
            StatuslinePayload.RateLimitWindow.self, from: Data(#"{"used_percentage":50}"#.utf8)
        )
        t.expectEqual(noReset.isExpired(at: now), false, "no resets_at means never expired")
    }

    t.run("staleStatuslineSampleCannotRegressQuota") { t in
        var reducer = FleetReducer()
        func payload(_ used: Double, resetsIn: TimeInterval) throws -> StatuslinePayload {
            let json = """
            {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":\(used),"resets_at":\(now.timeIntervalSince1970 + resetsIn)}}}
            """
            return try StatuslinePayload.decode(from: Data(json.utf8))
        }
        reducer.apply(.statusline(try payload(8, resetsIn: 3600), receivedAt: now))
        // Idle session re-renders with its stale view of the same window.
        reducer.apply(.statusline(try payload(5, resetsIn: 3600), receivedAt: now.addingTimeInterval(60)))
        t.expectEqual(reducer.snapshot.rateLimits?.fiveHour?.usedPercentage, 8, "stale sample rejected")
        // Genuine progress still lands.
        reducer.apply(.statusline(try payload(11, resetsIn: 3600), receivedAt: now.addingTimeInterval(120)))
        t.expectEqual(reducer.snapshot.rateLimits?.fiveHour?.usedPercentage, 11, "fresh sample accepted")
        // A NEW window may start low: lower % with a later resets_at is real.
        reducer.apply(.statusline(try payload(1, resetsIn: 3600 + 18_000), receivedAt: now.addingTimeInterval(300)))
        t.expectEqual(reducer.snapshot.rateLimits?.fiveHour?.usedPercentage, 1, "new window accepted")
    }

    t.run("expiredWindowDoesNotFireQuotaAlert") { t in
        var fleet = FleetSnapshot()
        let json = """
        {"five_hour":{"used_percentage":95,"resets_at":\(now.timeIntervalSince1970 - 60)}}
        """
        fleet.rateLimits = try JSONDecoder.statusline.decode(StatuslinePayload.RateLimits.self, from: Data(json.utf8))
        fleet.rateLimitsAsOf = now.addingTimeInterval(-3600)
        let alerts = AlertEngine.evaluate(fleet: fleet, config: .default, now: now, alreadyFired: [])
        t.expectEqual(alerts.count, 0, "stale window stays quiet")
    }
}
