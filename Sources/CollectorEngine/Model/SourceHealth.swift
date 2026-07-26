import Foundation

public enum SourceID: String, Sendable, Equatable, Hashable, CaseIterable {
    case registry
    case transcripts
    case statusline
    case process

    public var displayName: String {
        switch self {
        case .registry: "Session registry"
        case .transcripts: "Transcripts"
        case .statusline: "Statusline quota"
        case .process: "Process memory"
        }
    }

    public var affectedMetrics: String {
        switch self {
        case .registry: "Live sessions and status may be missing."
        case .transcripts: "Cache TTL, context, and model values may be stale."
        case .statusline: "Quota and actual session cost may be unavailable."
        case .process: "Memory and host-app attribution may be unavailable."
        }
    }

    public var suggestedAction: String {
        switch self {
        case .registry: "Verify ~/.claude/sessions exists and is readable."
        case .transcripts: "Update Cachewatch or attach the copied diagnostics to a bug report."
        case .statusline: "Run cachewatch setup, send a Claude turn, then check the forwarder."
        case .process: "Verify Cachewatch can run /bin/ps."
        }
    }
}

public enum SourceCondition: String, Sendable, Equatable {
    case healthy
    case stale
    case degraded
    case unavailable
    case notConfigured

    public var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .stale: "Stale"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        case .notConfigured: "Not configured"
        }
    }
}

/// Aggregate, privacy-safe coverage for one collector input. No source paths,
/// session IDs, or record contents are retained.
public struct SourceHealth: Sendable, Equatable, Identifiable {
    public let id: SourceID
    public var condition: SourceCondition
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var recordsSeen: Int
    public var recordsAccepted: Int
    public var recordsDropped: Int
    public var message: String?
    /// A healthy source becomes stale after this interval, measured from its last
    /// success or first attempt. Optional unconfigured sources omit it and stay quiet.
    public var staleAfter: TimeInterval?

    public init(
        id: SourceID,
        condition: SourceCondition,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        recordsSeen: Int = 0,
        recordsAccepted: Int = 0,
        recordsDropped: Int = 0,
        message: String? = nil,
        staleAfter: TimeInterval? = nil
    ) {
        self.id = id
        self.condition = condition
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.recordsSeen = recordsSeen
        self.recordsAccepted = recordsAccepted
        self.recordsDropped = recordsDropped
        self.message = message
        self.staleAfter = staleAfter
    }

    public func condition(at now: Date) -> SourceCondition {
        guard condition == .healthy,
              let staleAfter,
              let freshnessAnchor = lastSuccessAt ?? lastAttemptAt,
              now.timeIntervalSince(freshnessAnchor) > staleAfter
        else { return condition }
        return .stale
    }

    public func isWarning(at now: Date) -> Bool {
        switch condition(at: now) {
        case .healthy, .notConfigured: false
        case .stale, .degraded, .unavailable: true
        }
    }
}

public extension FleetSnapshot {
    func health(for source: SourceID) -> SourceHealth? {
        sourceHealth.first { $0.id == source }
    }

    func hasSourceWarning(at now: Date) -> Bool {
        sourceHealth.contains { $0.isWarning(at: now) }
    }

    func diagnosticSummary(at now: Date) -> String {
        let lines = SourceID.allCases.compactMap { id -> String? in
            guard let health = health(for: id) else { return nil }
            let condition = health.condition(at: now).displayName.lowercased()
            var fields = [
                "\(id.displayName): \(condition)",
                "seen=\(health.recordsSeen)",
                "accepted=\(health.recordsAccepted)",
                "dropped=\(health.recordsDropped)",
            ]
            if let attempt = health.lastAttemptAt {
                fields.append("attempt=\(Self.diagnosticAge(now.timeIntervalSince(attempt)))")
            }
            if let success = health.lastSuccessAt {
                fields.append("success=\(Self.diagnosticAge(now.timeIntervalSince(success)))")
            }
            if let message = health.message {
                fields.append(message)
            }
            return fields.joined(separator: " | ")
        }
        return (["Cachewatch data-source diagnostics"] + lines).joined(separator: "\n")
    }

    private static func diagnosticAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3_600)h ago"
    }
}
