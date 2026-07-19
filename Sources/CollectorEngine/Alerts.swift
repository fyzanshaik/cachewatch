import Foundation

public struct AlertConfig: Sendable, Equatable, Codable {
    public struct Quota: Sendable, Equatable, Codable {
        public var enabled = true
        public var thresholdPercentage = 80.0
    }

    public struct CacheExpiry: Sendable, Equatable, Codable {
        public var enabled = true
        public var warningSeconds = 90.0
        public var minContextTokens = 50_000
    }

    public struct LongIdle: Sendable, Equatable, Codable {
        public var enabled = true
        public var idleHours = 6.0
        public var minContextTokens = 100_000
        public var minMemoryBytes: UInt64 = 500_000_000
    }

    public var notificationsEnabled = true
    public var quota = Quota()
    public var cacheExpiry = CacheExpiry()
    public var longIdle = LongIdle()

    public static let `default` = AlertConfig()
}

public struct Alert: Sendable, Equatable {
    /// Dedup identity: an alert fires at most once per key (persisted across restarts).
    public let key: String
    public let title: String
    public let body: String
}

public enum AlertEngine {
    public static func evaluate(
        fleet: FleetSnapshot,
        config: AlertConfig,
        now: Date,
        alreadyFired: Set<String>
    ) -> [Alert] {
        guard config.notificationsEnabled else { return [] }
        var alerts: [Alert] = []
        if config.quota.enabled {
            alerts += quotaAlerts(fleet: fleet, config: config.quota)
        }
        if config.cacheExpiry.enabled {
            alerts += cacheExpiryAlerts(fleet: fleet, config: config.cacheExpiry, now: now)
        }
        if config.longIdle.enabled {
            alerts += longIdleAlerts(fleet: fleet, config: config.longIdle, now: now)
        }
        return alerts.filter { !alreadyFired.contains($0.key) }
    }

    private static func quotaAlerts(fleet: FleetSnapshot, config: AlertConfig.Quota) -> [Alert] {
        let windows: [(String, StatuslinePayload.RateLimitWindow?)] = [
            ("5h", fleet.rateLimits?.fiveHour),
            ("7d", fleet.rateLimits?.sevenDay),
        ]
        return windows.compactMap { label, window in
            guard let used = window?.usedPercentage, used >= config.thresholdPercentage else { return nil }
            let windowId = window?.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            return Alert(
                key: "quota-\(label)-\(windowId)",
                title: "Claude \(label) quota at \(Int(used))%",
                body: window?.resetsAt.map { "Resets \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            )
        }
    }

    private static func cacheExpiryAlerts(fleet: FleetSnapshot, config: AlertConfig.CacheExpiry, now: Date) -> [Alert] {
        fleet.sessions.compactMap { session in
            guard session.cacheTTL == .fiveMinutes,
                  case .warm(let expiresAt) = session.cacheState(at: now),
                  expiresAt.timeIntervalSince(now) <= config.warningSeconds,
                  let context = session.contextTokens, context >= config.minContextTokens,
                  let lastTurnAt = session.lastTurnAt
            else { return nil }
            return Alert(
                key: "cache-\(session.sessionId)-\(Int(lastTurnAt.timeIntervalSince1970))",
                title: "\(session.name ?? session.sessionId) cache expiring",
                body: "\(context / 1000)k-token cache dies in \(Int(expiresAt.timeIntervalSince(now)))s. Touch the session to keep it warm."
            )
        }
    }

    private static func longIdleAlerts(fleet: FleetSnapshot, config: AlertConfig.LongIdle, now: Date) -> [Alert] {
        fleet.sessions.compactMap { session in
            let idleSince = session.lastTurnAt ?? session.updatedAt
            guard now.timeIntervalSince(idleSince) >= config.idleHours * 3600,
                  let context = session.contextTokens, context >= config.minContextTokens,
                  let memory = session.memoryBytes, memory >= config.minMemoryBytes
            else { return nil }
            return Alert(
                key: "idle-\(session.sessionId)",
                title: "\(session.name ?? session.sessionId) idle for \(Int(now.timeIntervalSince(idleSince) / 3600))h",
                body: "Holding \(context / 1000)k tokens of context and \(memory / 1_000_000)MB of memory, cache cold. Consider closing it."
            )
        }
    }
}
