import Foundation

public enum CacheState: Sendable, Equatable {
    case warm(expiresAt: Date)
    case cold
    case unknown
}

public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let pid: Int32
    public let name: String?
    public let cwd: String
    public let status: SessionRegistryEntry.Status
    public let startedAt: Date
    public let updatedAt: Date

    public var model: String?
    public var gitBranch: String?
    public var contextTokens: Int?
    public var lastTurnAt: Date?
    public var cacheTTL: CacheTTL?
    public var costUSD: Double?
    public var contextUsedPercentage: Double?
    public var memoryBytes: UInt64?

    public var id: String { sessionId }

    /// Client-side expectation from last main turn + TTL bucket; the server may evict earlier.
    public func cacheState(at now: Date) -> CacheState {
        guard let lastTurnAt, let cacheTTL else { return .unknown }
        let expiresAt = lastTurnAt.addingTimeInterval(cacheTTL.duration)
        return now < expiresAt ? .warm(expiresAt: expiresAt) : .cold
    }
}

public struct FleetSnapshot: Sendable, Equatable {
    public var sessions: [SessionSnapshot] = []
    public var rateLimits: StatuslinePayload.RateLimits?
    public var rateLimitsAsOf: Date?

    public init() {}
}

public enum CollectorEvent: Sendable {
    case registrySnapshot([SessionRegistryEntry])
    case assistantTurn(AssistantTurn)
    case statusline(StatuslinePayload, receivedAt: Date)
    case memorySample(pid: Int32, residentBytes: UInt64)
}

/// Pure state machine: every source feeds events in, the canonical FleetSnapshot comes out.
/// Enrichment (turns, statusline) is keyed by sessionId and outlives registry churn, so
/// out-of-order arrival across sources converges to the same snapshot.
public struct FleetReducer: Sendable {
    private struct Enrichment {
        var model: String?
        var gitBranch: String?
        var contextTokens: Int?
        var lastTurnAt: Date?
        var cacheTTL: CacheTTL?
        var costUSD: Double?
        var contextUsedPercentage: Double?
    }

    private var registry: [SessionRegistryEntry] = []
    private var enrichments: [String: Enrichment] = [:]
    private var memoryByPid: [Int32: UInt64] = [:]
    private var rateLimits: StatuslinePayload.RateLimits?
    private var rateLimitsAsOf: Date?

    public init() {}

    public mutating func apply(_ event: CollectorEvent) {
        switch event {
        case .registrySnapshot(let entries):
            registry = entries

        case .assistantTurn(let turn):
            guard !turn.isSidechain else { return }
            var e = enrichments[turn.sessionId] ?? Enrichment()
            e.lastTurnAt = turn.timestamp
            if let model = turn.model { e.model = model }
            if let branch = turn.gitBranch { e.gitBranch = branch }
            if let usage = turn.usage {
                e.contextTokens = usage.contextTokens
                if let ttl = usage.cacheTTL { e.cacheTTL = ttl }
            }
            enrichments[turn.sessionId] = e

        case .statusline(let payload, let receivedAt):
            var e = enrichments[payload.sessionId] ?? Enrichment()
            if let cost = payload.cost?.totalCostUSD { e.costUSD = cost }
            if let pct = payload.contextWindow?.usedPercentage { e.contextUsedPercentage = pct }
            if let model = payload.model?.id { e.model = model }
            enrichments[payload.sessionId] = e
            if let limits = payload.rateLimits {
                rateLimits = limits
                rateLimitsAsOf = receivedAt
            }

        case .memorySample(let pid, let residentBytes):
            memoryByPid[pid] = residentBytes
        }
    }

    public var snapshot: FleetSnapshot {
        var fleet = FleetSnapshot()
        fleet.rateLimits = rateLimits
        fleet.rateLimitsAsOf = rateLimitsAsOf
        fleet.sessions = registry.map { entry in
            let e = enrichments[entry.sessionId]
            var s = SessionSnapshot(
                sessionId: entry.sessionId,
                pid: entry.pid,
                name: entry.name,
                cwd: entry.cwd,
                status: entry.status,
                startedAt: entry.startedAt,
                updatedAt: entry.updatedAt
            )
            s.model = e?.model
            s.gitBranch = e?.gitBranch
            s.contextTokens = e?.contextTokens
            s.lastTurnAt = e?.lastTurnAt
            s.cacheTTL = e?.cacheTTL
            s.costUSD = e?.costUSD
            s.contextUsedPercentage = e?.contextUsedPercentage
            s.memoryBytes = memoryByPid[entry.pid]
            return s
        }
        return fleet
    }
}
