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

    public struct CacheMiss: Sendable, Equatable, Codable {
        public var enabled = true
    }

    public struct NeedsInput: Sendable, Equatable, Codable {
        public var enabled = true
        public var afterSeconds = 120.0
    }

    public struct TurnFinished: Sendable, Equatable, Codable {
        public var enabled = true
        public var minBusySeconds = 300.0
    }

    public var notificationsEnabled = true
    public var quota = Quota()
    public var cacheExpiry = CacheExpiry()
    public var longIdle = LongIdle()
    public var cacheMiss = CacheMiss()
    public var needsInput = NeedsInput()
    public var turnFinished = TurnFinished()

    public static let `default` = AlertConfig()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, quota, cacheExpiry, longIdle, cacheMiss, needsInput, turnFinished
    }

    // Tolerant of state.json written before a rule existed: missing sections default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        quota = try c.decodeIfPresent(Quota.self, forKey: .quota) ?? Quota()
        cacheExpiry = try c.decodeIfPresent(CacheExpiry.self, forKey: .cacheExpiry) ?? CacheExpiry()
        longIdle = try c.decodeIfPresent(LongIdle.self, forKey: .longIdle) ?? LongIdle()
        cacheMiss = try c.decodeIfPresent(CacheMiss.self, forKey: .cacheMiss) ?? CacheMiss()
        needsInput = try c.decodeIfPresent(NeedsInput.self, forKey: .needsInput) ?? NeedsInput()
        turnFinished = try c.decodeIfPresent(TurnFinished.self, forKey: .turnFinished) ?? TurnFinished()
    }
}

public struct Alert: Sendable, Equatable {
    /// Dedup identity: an alert fires at most once per key (persisted across restarts).
    public let key: String
    public let title: String
    public let body: String

    public init(key: String, title: String, body: String) {
        self.key = key
        self.title = title
        self.body = body
    }
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
            alerts += quotaAlerts(
                limits: fleet.rateLimits,
                providerKey: nil,
                providerName: "Claude",
                config: config.quota,
                now: now
            )
            alerts += quotaAlerts(
                limits: fleet.codexRateLimits,
                providerKey: "codex",
                providerName: "Codex",
                config: config.quota,
                now: now
            )
        }
        if config.cacheExpiry.enabled {
            alerts += cacheExpiryAlerts(fleet: fleet, config: config.cacheExpiry, now: now)
        }
        if config.longIdle.enabled {
            alerts += longIdleAlerts(fleet: fleet, config: config.longIdle, now: now)
        }
        if config.cacheMiss.enabled {
            alerts += cacheMissAlerts(fleet: fleet)
        }
        if config.needsInput.enabled {
            alerts += needsInputAlerts(fleet: fleet, config: config.needsInput, now: now)
        }
        if config.turnFinished.enabled {
            alerts += turnFinishedAlerts(fleet: fleet, config: config.turnFinished)
        }
        return alerts.filter { !alreadyFired.contains($0.key) }
    }

    private static func quotaAlerts(
        limits: StatuslinePayload.RateLimits?,
        providerKey: String?,
        providerName: String,
        config: AlertConfig.Quota,
        now: Date
    ) -> [Alert] {
        let windows: [(String, StatuslinePayload.RateLimitWindow?)] = [
            ("5h", limits?.fiveHour),
            ("7d", limits?.sevenDay),
        ]
        return windows.compactMap { label, window in
            guard let used = window?.usedPercentage, used >= config.thresholdPercentage,
                  window?.isExpired(at: now) != true
            else { return nil }
            let windowId = window?.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            let keyPrefix = providerKey.map { "quota-\($0)" } ?? "quota"
            return Alert(
                key: "\(keyPrefix)-\(label)-\(windowId)",
                title: "\(providerName) \(label) quota at \(Int(used))%",
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

    private static func cacheMissAlerts(fleet: FleetSnapshot) -> [Alert] {
        fleet.sessions.compactMap { session in
            guard let missAt = session.lastCacheMissAt else { return nil }
            return Alert(
                key: "miss-\(session.sessionId)-\(Int(missAt.timeIntervalSince1970))",
                title: "\(session.name ?? session.sessionId) paid a silent cache miss",
                body: "A turn rewrote the full context while the cache should have been warm. Usual causes: Claude Code upgrade, model/effort switch, or MCP server change."
            )
        }
    }

    private static func needsInputAlerts(fleet: FleetSnapshot, config: AlertConfig.NeedsInput, now: Date) -> [Alert] {
        fleet.sessions.compactMap { session in
            guard session.status == .waiting,
                  let since = session.statusChangedAt,
                  now.timeIntervalSince(since) >= config.afterSeconds
            else { return nil }
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return Alert(
                key: "input-\(session.sessionId)-\(Int(since.timeIntervalSince1970))",
                title: "\(session.name ?? session.sessionId) needs your input",
                body: "Waiting \(minutes)m\(session.hostAppName.map { " in \($0)" } ?? "") — its cache keeps burning down while it waits."
            )
        }
    }

    private static func turnFinishedAlerts(fleet: FleetSnapshot, config: AlertConfig.TurnFinished) -> [Alert] {
        fleet.sessions.compactMap { session in
            guard let endedAt = session.lastBusyEndAt,
                  let duration = session.lastBusyDuration, duration >= config.minBusySeconds
            else { return nil }
            return Alert(
                key: "finished-\(session.sessionId)-\(Int(endedAt.timeIntervalSince1970))",
                title: "\(session.name ?? session.sessionId) finished a \(Int(duration / 60))m turn",
                body: "Long-running work just completed\(session.hostAppName.map { " in \($0)" } ?? "") — worth a review."
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
                body: "Holding \(context / 1000)k tokens of context and \(memory / 1_000_000)MB of memory"
                    + (session.provider == .claude ? ", cache cold" : "")
                    + ". Consider closing it."
            )
        }
    }
}
