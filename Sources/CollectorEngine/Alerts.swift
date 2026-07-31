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
    /// Number of underlying alert conditions represented by this presentation item.
    public let representedCount: Int

    public init(key: String, title: String, body: String, representedCount: Int = 1) {
        self.key = key
        self.title = title
        self.body = body
        self.representedCount = max(1, representedCount)
    }
}

/// Presentation state for one-at-a-time alert surfaces. Timing belongs to the
/// presenter; advancing the queue never depends on SwiftUI view identity.
public struct AlertPresentationQueue: Sendable, Equatable {
    public private(set) var current: Alert?
    private var pending: [Alert] = []
    private let maxPendingAlerts: Int
    private var overflowCount = 0
    private var firstOverflowKey: String?

    public init(maxPendingAlerts: Int = 3) {
        self.maxPendingAlerts = max(0, maxPendingAlerts)
    }

    /// Returns the alert to present when the queue was idle, otherwise retains it.
    @discardableResult
    public mutating func enqueue(_ alert: Alert) -> Alert? {
        guard current == nil else {
            if pending.count < maxPendingAlerts {
                pending.append(alert)
            } else {
                overflowCount += alert.representedCount
                firstOverflowKey = firstOverflowKey ?? alert.key
            }
            return nil
        }
        current = alert
        return alert
    }

    /// Completes the current presentation and returns the next alert, if any.
    @discardableResult
    public mutating func advance() -> Alert? {
        if !pending.isEmpty {
            current = pending.removeFirst()
        } else if overflowCount > 0 {
            let count = overflowCount
            current = AlertDeliveryBatch.summary(count: count, firstOmittedKey: firstOverflowKey)
            overflowCount = 0
            firstOverflowKey = nil
        } else {
            current = nil
        }
        return current
    }

    /// Removes every retained presentation so another delivery surface can take over.
    /// This intentionally includes the currently visible alert: display loss uses
    /// at-least-once delivery because a banner that vanished mid-presentation may
    /// not have been seen.
    public mutating func drain() -> [Alert] {
        var alerts = current.map { [$0] } ?? []
        alerts.append(contentsOf: pending)
        if overflowCount > 0 {
            alerts.append(AlertDeliveryBatch.summary(count: overflowCount, firstOmittedKey: firstOverflowKey))
        }
        current = nil
        pending.removeAll()
        overflowCount = 0
        firstOverflowKey = nil
        return alerts
    }
}

public enum AlertDeliveryBatch {
    public static func make(from alerts: [Alert], maxIndividualAlerts: Int = 3) -> [Alert] {
        let limit = max(0, maxIndividualAlerts)
        guard alerts.count > limit else { return alerts }
        let omitted = alerts.dropFirst(limit).reduce(0) { $0 + $1.representedCount }
        let firstOmittedKey = alerts[limit].key
        return Array(alerts.prefix(limit)) + [summary(count: omitted, firstOmittedKey: firstOmittedKey)]
    }

    static func summary(count: Int, firstOmittedKey: String?) -> Alert {
        Alert(
            key: "notification-summary-\(firstOmittedKey ?? "overflow")",
            title: "\(count) more Cachewatch alert\(count == 1 ? "" : "s")",
            body: "Open Cachewatch to review the sessions that need attention.",
            representedCount: count
        )
    }
}

public enum AlertDeliveryRoute: Sendable, Equatable {
    case custom
    case native
    case legacy

    public static func choose(customSurfaceAccepted: Bool, isBundledApp: Bool) -> Self {
        if customSurfaceAccepted { return .custom }
        return isBundledApp ? .native : .legacy
    }
}

public enum AlertSurfaceVisibility {
    public static func shouldOrderFront(
        hasNotchedScreen: Bool,
        hudEnabled: Bool,
        hasTransientContent: Bool
    ) -> Bool {
        hasNotchedScreen && (hudEnabled || hasTransientContent)
    }

    public static func shouldCollapseTransientState(
        hasNotchedScreen: Bool,
        isExpanded: Bool
    ) -> Bool {
        !hasNotchedScreen && isExpanded
    }
}

public enum AlertSurfaceInteraction {
    public static func shouldIgnoreMouseEvents(isInformationalAlert: Bool) -> Bool {
        isInformationalAlert
    }
}

public struct AlertDisplay: Sendable, Equatable {
    public let id: Int
    public let hasNotch: Bool

    public init(id: Int, hasNotch: Bool) {
        self.id = id
        self.hasNotch = hasNotch
    }
}

public enum AlertDisplayPolicy {
    public static func customSurfaceTarget(
        activeDisplayID: Int?,
        connectedDisplays: [AlertDisplay]
    ) -> AlertDisplay? {
        guard let activeDisplayID,
              let active = connectedDisplays.first(where: { $0.id == activeDisplayID }),
              active.hasNotch
        else { return nil }
        return active
    }
}

public struct AlertPresentationDisplay: Sendable, Equatable {
    public private(set) var displayID: Int?

    public init() {}

    public mutating func accept(displayID: Int) {
        self.displayID = displayID
    }

    public mutating func clear() {
        displayID = nil
    }

    public func connectedTarget(in displays: [AlertDisplay]) -> AlertDisplay? {
        AlertDisplayPolicy.customSurfaceTarget(
            activeDisplayID: displayID,
            connectedDisplays: displays
        )
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
            alerts += quotaAlerts(fleet: fleet, config: config.quota, now: now)
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

    private static func quotaAlerts(fleet: FleetSnapshot, config: AlertConfig.Quota, now: Date) -> [Alert] {
        let windows: [(String, StatuslinePayload.RateLimitWindow?)] = [
            ("5h", fleet.rateLimits?.fiveHour),
            ("7d", fleet.rateLimits?.sevenDay),
        ]
        return windows.compactMap { label, window in
            guard let used = window?.usedPercentage, used >= config.thresholdPercentage,
                  window?.isExpired(at: now) != true
            else { return nil }
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
                body: "Holding \(context / 1000)k tokens of context and \(memory / 1_000_000)MB of memory, cache cold. Consider closing it."
            )
        }
    }
}
