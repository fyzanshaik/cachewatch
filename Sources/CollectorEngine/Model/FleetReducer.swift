import Foundation

public enum CacheState: Sendable, Equatable {
    case warm(expiresAt: Date)
    case cold
    case unknown
}

public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let pid: Int32
    public let provider: SessionProvider
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
    /// Timestamp of the last turn that paid a full rewrite while the cache should
    /// have been warm — the silent cache-miss signature (resume/upgrade regressions).
    public var lastCacheMissAt: Date?
    /// When the current status began (registry statusUpdatedAt).
    public var statusChangedAt: Date?
    /// Most recent busy→non-busy transition and how long that turn ran.
    public var lastBusyEndAt: Date?
    public var lastBusyDuration: TimeInterval?
    /// App bundle hosting this session's process tree (cmux, iTerm2, ...).
    public var hostAppName: String?
    public var hostAppPid: Int32?

    public var id: String { sessionId }

    public init(sessionId: String, pid: Int32, provider: SessionProvider = .claude, name: String?, cwd: String,
                status: SessionRegistryEntry.Status, startedAt: Date, updatedAt: Date) {
        self.sessionId = sessionId
        self.pid = pid
        self.provider = provider
        self.name = name
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// Client-side expectation from last main turn + TTL bucket; the server may evict earlier.
    public func cacheState(at now: Date) -> CacheState {
        guard let lastTurnAt, let cacheTTL else { return .unknown }
        let expiresAt = lastTurnAt.addingTimeInterval(cacheTTL.duration)
        return now < expiresAt ? .warm(expiresAt: expiresAt) : .cold
    }
}

public struct FleetSnapshot: Sendable, Equatable {
    public var sessions: [SessionSnapshot] = []
    /// Claude Code subscription/API rate limits from its statusline payload.
    public var rateLimits: StatuslinePayload.RateLimits?
    public var rateLimitsAsOf: Date?
    /// Codex ChatGPT rate limits reconstructed from live rollout token events.
    public var codexRateLimits: StatuslinePayload.RateLimits?
    public var codexRateLimitsAsOf: Date?
    /// API-priced spend across all sessions and subagents since launch replay.
    public var cumulativeTurnCostUSD = 0.0
    public var calibration = QuotaCalibrator()

    public init() {}
}

public enum CollectorEvent: Sendable {
    case registrySnapshot([SessionRegistryEntry])
    case assistantTurn(AssistantTurn)
    case codexSession(CodexRolloutSnapshot)
    case statusline(StatuslinePayload, receivedAt: Date)
    case memorySample(pid: Int32, residentBytes: UInt64, host: ProcessTree.Host? = nil)
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
        var lastCacheMissAt: Date?
        var lastBusyEndAt: Date?
        var lastBusyDuration: TimeInterval?
    }

    /// Rewrites smaller than this are prefix-invalidation noise, not a full miss.
    private static let cacheMissMinRewriteTokens = 50_000

    private var registry: [SessionRegistryEntry] = []
    private var enrichments: [String: Enrichment] = [:]
    private var memoryByPid: [Int32: UInt64] = [:]
    private var hostByPid: [Int32: ProcessTree.Host?] = [:]
    private var rateLimits: StatuslinePayload.RateLimits?
    private var rateLimitsAsOf: Date?
    private var codexRateLimits: StatuslinePayload.RateLimits?
    private var codexRateLimitsAsOf: Date?
    private var cumulativeTurnCostUSD = 0.0
    private var calibration: QuotaCalibrator

    public init(
        calibration: QuotaCalibrator = QuotaCalibrator(),
        rateLimits: StatuslinePayload.RateLimits? = nil,
        rateLimitsAsOf: Date? = nil
    ) {
        self.calibration = calibration
        self.rateLimits = rateLimits
        self.rateLimitsAsOf = rateLimitsAsOf
    }

    public mutating func apply(_ event: CollectorEvent) {
        switch event {
        case .registrySnapshot(let entries):
            let previous = Dictionary(registry.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
            for entry in entries {
                guard let old = previous[entry.sessionId],
                      old.status == .busy, entry.status != .busy
                else { continue }
                var e = enrichments[entry.sessionId] ?? Enrichment()
                e.lastBusyEndAt = entry.statusUpdatedAt
                e.lastBusyDuration = entry.statusUpdatedAt.timeIntervalSince(old.statusUpdatedAt)
                enrichments[entry.sessionId] = e
            }
            registry = entries

        case .assistantTurn(let turn):
            if let usage = turn.usage, let model = turn.model,
               let cost = Pricing.turnCostUSD(model: model, usage: usage) {
                cumulativeTurnCostUSD += cost
            }
            guard !turn.isSidechain else { return }
            var e = enrichments[turn.sessionId] ?? Enrichment()
            if let usage = turn.usage,
               let previousTurnAt = e.lastTurnAt, let previousTTL = e.cacheTTL,
               turn.timestamp < previousTurnAt.addingTimeInterval(previousTTL.duration),
               usage.cacheReadInputTokens == 0,
               usage.cacheCreationInputTokens >= Self.cacheMissMinRewriteTokens {
                e.lastCacheMissAt = turn.timestamp
            }
            e.lastTurnAt = turn.timestamp
            if let model = turn.model { e.model = model }
            if let branch = turn.gitBranch { e.gitBranch = branch }
            if let usage = turn.usage {
                e.contextTokens = usage.contextTokens
                if let ttl = usage.cacheTTL { e.cacheTTL = ttl }
            }
            enrichments[turn.sessionId] = e

        case .codexSession(let session):
            var enrichment = enrichments[session.sessionId] ?? Enrichment()
            enrichment.model = session.model ?? enrichment.model
            enrichment.gitBranch = session.gitBranch ?? enrichment.gitBranch
            enrichment.contextTokens = session.contextTokens ?? enrichment.contextTokens
            enrichment.contextUsedPercentage = session.contextUsedPercentage ?? enrichment.contextUsedPercentage
            enrichment.lastTurnAt = session.lastTurnAt ?? enrichment.lastTurnAt
            enrichments[session.sessionId] = enrichment

            if let limits = session.rateLimits {
                let merged = StatuslinePayload.RateLimits(
                    fiveHour: mergeWindow(current: codexRateLimits?.fiveHour, incoming: limits.fiveHour),
                    sevenDay: mergeWindow(current: codexRateLimits?.sevenDay, incoming: limits.sevenDay)
                )
                if merged != codexRateLimits {
                    codexRateLimits = merged
                    codexRateLimitsAsOf = session.lastTurnAt ?? session.updatedAt
                }
            }

        case .statusline(let payload, let receivedAt):
            var e = enrichments[payload.sessionId] ?? Enrichment()
            if let cost = payload.cost?.totalCostUSD { e.costUSD = cost }
            if let pct = payload.contextWindow?.usedPercentage { e.contextUsedPercentage = pct }
            if let model = payload.model?.id { e.model = model }
            enrichments[payload.sessionId] = e
            if let limits = payload.rateLimits {
                // Statusline rate_limits reflect the SENDING session's last API
                // response; idle sessions re-rendering on refreshInterval report
                // stale values. Within one window used-% only ever grows, so a
                // regression means staleness — merge monotonically per window.
                let merged = StatuslinePayload.RateLimits(
                    fiveHour: mergeWindow(current: rateLimits?.fiveHour, incoming: limits.fiveHour),
                    sevenDay: mergeWindow(current: rateLimits?.sevenDay, incoming: limits.sevenDay)
                )
                if merged != rateLimits {
                    rateLimits = merged
                    rateLimitsAsOf = receivedAt
                }
                if let used = merged.fiveHour?.usedPercentage {
                    calibration.observe(
                        cumulativeCostUSD: cumulativeTurnCostUSD,
                        usedPercentage: used,
                        resetsAt: merged.fiveHour?.resetsAt
                    )
                }
            }

        case .memorySample(let pid, let residentBytes, let host):
            memoryByPid[pid] = residentBytes
            hostByPid[pid] = host
        }
    }

    private func mergeWindow(
        current: StatuslinePayload.RateLimitWindow?,
        incoming: StatuslinePayload.RateLimitWindow?
    ) -> StatuslinePayload.RateLimitWindow? {
        guard let incoming else { return current }
        guard let current, current.resetsAt == incoming.resetsAt,
              let currentUsed = current.usedPercentage,
              let incomingUsed = incoming.usedPercentage,
              incomingUsed < currentUsed
        else { return incoming }
        return current
    }

    public var snapshot: FleetSnapshot {
        var fleet = FleetSnapshot()
        fleet.rateLimits = rateLimits
        fleet.rateLimitsAsOf = rateLimitsAsOf
        fleet.codexRateLimits = codexRateLimits
        fleet.codexRateLimitsAsOf = codexRateLimitsAsOf
        fleet.cumulativeTurnCostUSD = cumulativeTurnCostUSD
        fleet.calibration = calibration
        fleet.sessions = registry.map { entry in
            let e = enrichments[entry.sessionId]
            var s = SessionSnapshot(
                sessionId: entry.sessionId,
                pid: entry.pid,
                provider: entry.provider,
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
            s.lastCacheMissAt = e?.lastCacheMissAt
            s.statusChangedAt = entry.statusUpdatedAt
            s.lastBusyEndAt = e?.lastBusyEndAt
            s.lastBusyDuration = e?.lastBusyDuration
            let host = hostByPid[entry.pid] ?? nil
            s.hostAppName = host?.name
            s.hostAppPid = host?.pid
            return s
        }
        return fleet
    }
}
