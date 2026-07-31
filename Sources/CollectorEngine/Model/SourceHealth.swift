import Foundation

public enum SourceID: String, CaseIterable, Sendable, Equatable, Identifiable {
    case registry
    case transcripts
    case statusline
    case process

    public var id: String { rawValue }

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
        case .registry: "Live session and status data"
        case .transcripts: "Cache, context, model, and turn-cost data"
        case .statusline: "Quota and actual session-cost data"
        case .process: "Memory and host-app data"
        }
    }

    fileprivate var staleAfter: TimeInterval {
        switch self {
        case .registry, .transcripts: 10
        case .process: 20
        case .statusline: 15 * 60
        }
    }
}

public enum SessionMetric: Sendable {
    case context
    case cache
    case cost
    case memory

    public var source: SourceID {
        switch self {
        case .context, .cache: .transcripts
        case .cost: .statusline
        case .memory: .process
        }
    }
}

public enum SourceCondition: String, Sendable, Equatable {
    case healthy
    case stale
    case degraded
    case unavailable
    case notConfigured = "not configured"
}

public struct SourceHealth: Sendable, Equatable, Identifiable {
    public let id: SourceID
    public var condition: SourceCondition
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var recordsSeen: Int
    public var recordsAccepted: Int
    public var recordsDropped: Int
    /// Controlled, content-free user guidance. Diagnostics intentionally omit it.
    public var message: String?

    public init(
        id: SourceID,
        condition: SourceCondition,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        recordsSeen: Int = 0,
        recordsAccepted: Int = 0,
        recordsDropped: Int = 0,
        message: String? = nil
    ) {
        self.id = id
        self.condition = condition
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.recordsSeen = recordsSeen
        self.recordsAccepted = recordsAccepted
        self.recordsDropped = recordsDropped
        self.message = message
    }

    /// Freshness is derived from snapshot data plus an explicit clock so the
    /// reducer stays pure and TimelineView can update without synthetic events.
    public func currentCondition(at now: Date) -> SourceCondition {
        guard condition == .healthy,
              let reference = lastSuccessAt ?? lastAttemptAt,
              now.timeIntervalSince(reference) > id.staleAfter
        else { return condition }
        return .stale
    }

    public func isWarning(at now: Date) -> Bool {
        switch currentCondition(at: now) {
        case .stale, .degraded, .unavailable: true
        case .healthy, .notConfigured: false
        }
    }
}

public extension FleetSnapshot {
    func sourceHealth(for id: SourceID) -> SourceHealth? {
        sourceHealth.first { $0.id == id }
    }

    func warningSources(at now: Date) -> [SourceHealth] {
        sourceHealth.filter { $0.isWarning(at: now) }
    }

    func metricQualifier(for id: SourceID, at now: Date) -> String? {
        guard let health = sourceHealth(for: id) else { return nil }
        return switch health.currentCondition(at: now) {
        case .healthy: nil
        case .stale: "stale"
        case .degraded, .unavailable: "incomplete"
        case .notConfigured: "unavailable"
        }
    }

    /// Copyable and deliberately schema-safe: no paths, errors, prompts, or
    /// source-provided free-form messages are included.
    func diagnosticsSummary(at now: Date) -> String {
        let lines = sourceHealth.sorted { sourceOrder($0.id) < sourceOrder($1.id) }.map { health in
            var fields = [
                "\(health.id.rawValue): \(health.currentCondition(at: now).rawValue)",
                "seen=\(health.recordsSeen)",
                "accepted=\(health.recordsAccepted)",
                "dropped=\(health.recordsDropped)",
            ]
            if let attempt = health.lastAttemptAt {
                fields.append("attemptAge=\(max(0, Int(now.timeIntervalSince(attempt))))s")
            }
            if let success = health.lastSuccessAt {
                fields.append("successAge=\(max(0, Int(now.timeIntervalSince(success))))s")
            }
            return fields.joined(separator: "; ")
        }
        return (["Cachewatch data-source diagnostics"] + lines).joined(separator: "\n")
    }

    private func sourceOrder(_ id: SourceID) -> Int {
        SourceID.allCases.firstIndex(of: id) ?? SourceID.allCases.count
    }
}
