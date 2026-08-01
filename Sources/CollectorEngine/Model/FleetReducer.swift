import Foundation

public enum CacheState: Sendable, Equatable {
    case warm(expiresAt: Date)
    case cold
    case unknown
}

public enum CacheEvidenceQuality: Sendable, Equatable {
    case insufficient
    case incomplete
    case sufficient
}

public enum CacheInterpretation: Sendable, Equatable {
    case insufficientEvidence
    case incompleteData
    case warmMissObserved
    case awaitingLargeWriteReuse
    case largeWriteTTLUnknown
    case largeWriteNotReused
    case strongReuse
    case limitedReuse
    case neutral
}

public struct CacheActivitySummary: Sendable, Equatable {
    static let maxTrackedTurns = 1_024

    public internal(set) var assistantTurns = 0
    public internal(set) var turnsWithCompleteUsage = 0
    public internal(set) var incompleteUsageTurns = 0
    public internal(set) var inputTokens = 0
    public internal(set) var outputTokens = 0
    public internal(set) var cacheReadTokens = 0
    public internal(set) var cacheWriteTokens = 0
    public internal(set) var fiveMinuteWriteTokens = 0
    public internal(set) var oneHourWriteTokens = 0
    public internal(set) var unclassifiedWriteTokens = 0

    public var evidenceQuality: CacheEvidenceQuality {
        guard assistantTurns >= 2 else { return .insufficient }
        guard incompleteUsageTurns == 0 else { return .incomplete }
        return turnsWithCompleteUsage >= 2 ? .sufficient : .insufficient
    }

    public var cacheEligibleHitRatio: Double? {
        guard evidenceQuality == .sufficient else { return nil }
        let eligible = Double(cacheReadTokens) + Double(cacheWriteTokens)
        guard eligible > 0 else { return nil }
        return Double(cacheReadTokens) / eligible
    }

    @discardableResult
    mutating func observe(_ usage: TurnUsage?) -> Bool {
        guard assistantTurns < Self.maxTrackedTurns else {
            incompleteUsageTurns = max(incompleteUsageTurns, 1)
            return false
        }
        assistantTurns += 1
        guard let usage, usage.isCompleteForCacheSummary else {
            incompleteUsageTurns += 1
            return false
        }

        let (nextInput, inputOverflow) = inputTokens.addingReportingOverflow(usage.inputTokens)
        let (nextOutput, outputOverflow) = outputTokens.addingReportingOverflow(usage.outputTokens)
        let (nextRead, readOverflow) = cacheReadTokens.addingReportingOverflow(usage.cacheReadInputTokens)
        let (nextWrite, writeOverflow) = cacheWriteTokens.addingReportingOverflow(usage.cacheCreationInputTokens)
        let (nextFiveMinute, fiveMinuteOverflow) = fiveMinuteWriteTokens.addingReportingOverflow(usage.ephemeral5mTokens)
        let (nextOneHour, oneHourOverflow) = oneHourWriteTokens.addingReportingOverflow(usage.ephemeral1hTokens)
        let (nextUnclassified, unclassifiedOverflow) = unclassifiedWriteTokens.addingReportingOverflow(
            usage.unclassifiedCacheCreationTokens
        )
        guard !inputOverflow,
              !outputOverflow,
              !readOverflow,
              !writeOverflow,
              !fiveMinuteOverflow,
              !oneHourOverflow,
              !unclassifiedOverflow
        else {
            incompleteUsageTurns += 1
            return false
        }

        turnsWithCompleteUsage += 1
        inputTokens = nextInput
        outputTokens = nextOutput
        cacheReadTokens = nextRead
        cacheWriteTokens = nextWrite
        fiveMinuteWriteTokens = nextFiveMinute
        oneHourWriteTokens = nextOneHour
        unclassifiedWriteTokens = nextUnclassified
        return true
    }
}

public struct SessionCacheSummary: Sendable, Equatable {
    public static let largeWriteMinTokens = 50_000

    public internal(set) var main = CacheActivitySummary()
    public internal(set) var sidechains = CacheActivitySummary()
    public internal(set) var fullWarmMisses = 0
    public internal(set) var lastLargeWriteTokens: Int?
    public internal(set) var lastLargeWriteHasKnownTTL = false
    public internal(set) var lastLargeWriteExpired = false
    public internal(set) var turnsAfterLastLargeWrite = 0
    public internal(set) var lastLargeWriteReuseTurns = 0
    public internal(set) var attributionIsComplete = true

    public var interpretation: CacheInterpretation {
        guard attributionIsComplete else { return .incompleteData }
        switch main.evidenceQuality {
        case .insufficient:
            return .insufficientEvidence
        case .incomplete:
            return .incompleteData
        case .sufficient:
            if fullWarmMisses > 0 { return .warmMissObserved }
            if lastLargeWriteTokens != nil,
               !lastLargeWriteHasKnownTTL {
                return .largeWriteTTLUnknown
            }
            if lastLargeWriteTokens != nil,
               lastLargeWriteExpired {
                return .largeWriteNotReused
            }
            if lastLargeWriteTokens != nil,
               turnsAfterLastLargeWrite == 0 {
                return .awaitingLargeWriteReuse
            }
            if lastLargeWriteTokens != nil,
               turnsAfterLastLargeWrite > 0,
               lastLargeWriteReuseTurns == 0 {
                return .largeWriteNotReused
            }
            guard main.assistantTurns >= 3,
                  let ratio = main.cacheEligibleHitRatio
            else { return .neutral }
            if ratio >= 0.8 { return .strongReuse }
            if ratio < 0.3 { return .limitedReuse }
            return .neutral
        }
    }

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
    public var cacheEvidenceAt: Date?
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
    public var cacheSummary: SessionCacheSummary?

    public var id: String { sessionId }

    public init(sessionId: String, pid: Int32, name: String?, cwd: String,
                status: SessionRegistryEntry.Status, startedAt: Date, updatedAt: Date) {
        self.sessionId = sessionId
        self.pid = pid
        self.name = name
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// Client-side expectation from the last trusted cache observation + TTL bucket;
    /// the server may evict earlier.
    public func cacheState(at now: Date) -> CacheState {
        guard let cacheEvidenceAt = cacheEvidenceAt ?? lastTurnAt,
              let cacheTTL
        else { return .unknown }
        let expiresAt = cacheEvidenceAt.addingTimeInterval(cacheTTL.duration)
        return now < expiresAt ? .warm(expiresAt: expiresAt) : .cold
    }
}

public struct FleetSnapshot: Sendable, Equatable {
    public var sessions: [SessionSnapshot] = []
    public var rateLimits: StatuslinePayload.RateLimits?
    public var rateLimitsAsOf: Date?
    public var sourceHealth: [SourceHealth] = []
    /// API-priced spend across all sessions and subagents since launch replay.
    public var cumulativeTurnCostUSD = 0.0
    public var calibration = QuotaCalibrator()

    public init() {}
}

public enum CollectorEvent: Sendable {
    case registrySnapshot([SessionRegistryEntry])
    case assistantTurn(AssistantTurn)
    case statusline(StatuslinePayload, receivedAt: Date)
    case memorySample(pid: Int32, residentBytes: UInt64, host: ProcessTree.Host? = nil)
    case sourceHealth(SourceHealth)
}

/// Pure state machine: every source feeds events in, the canonical FleetSnapshot comes out.
/// Enrichment (turns, statusline) is keyed by sessionId and outlives registry churn, so
/// out-of-order arrival across sources converges to the same snapshot.
public struct FleetReducer: Sendable {
    private struct LargeWriteCandidate: Sendable {
        let createdAt: Date
        let writeTokens: Int
        let baselineReadTokens: Int
        let ttl: CacheTTL
        var effectiveExpiresAt: Date
    }

    private struct WarmMissEvidence: Sendable {
        let previousTurnAt: Date
        let missAt: Date
    }

    private struct CacheAttributionObservation: Sendable {
        let timestamp: Date
        let model: String?
        let gitBranch: String?
        let usage: TurnUsage?
    }

    private struct Enrichment {
        var statuslineModel: String?
        var transcriptModel: String?
        var transcriptGitBranch: String?
        var transcriptContextTokens: Int?
        var transcriptLastTurnAt: Date?
        var transcriptCacheEvidenceAt: Date?
        var transcriptCacheTTL: CacheTTL?
        var costUSD: Double?
        var contextUsedPercentage: Double?
        var lastCacheMissAt: Date?
        var lastBusyEndAt: Date?
        var lastBusyDuration: TimeInterval?
        var cacheSummary: SessionCacheSummary?
        var latestCompleteCacheTurnAt: Date?
        var latestCompleteCacheTTL: CacheTTL?
        var latestLargeWrite: LargeWriteCandidate?
        var warmMisses: [WarmMissEvidence] = []
        var cacheAttributionObservations: [CacheAttributionObservation] = []
        var cacheAttributionOverflowed = false
        var sidechainCacheObservations: [CacheAttributionObservation] = []
        var sidechainCacheOverflowed = false
    }

    /// Rewrites smaller than this are prefix-invalidation noise, not a full miss.
    private static let cacheMissMinRewriteTokens = 50_000
    private static let maxCacheAttributionObservations = CacheActivitySummary.maxTrackedTurns

    private var registry: [SessionRegistryEntry] = []
    private var enrichments: [String: Enrichment] = [:]
    private var memoryByPid: [Int32: UInt64] = [:]
    private var hostByPid: [Int32: ProcessTree.Host?] = [:]
    private var sourceHealthByID: [SourceID: SourceHealth] = [:]
    private var rateLimits: StatuslinePayload.RateLimits?
    private var rateLimitsAsOf: Date?
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
               let cost = Pricing.turnCostUSD(model: model, usage: usage, at: turn.timestamp) {
                let nextCost = cumulativeTurnCostUSD + cost
                cumulativeTurnCostUSD = nextCost.isFinite ? nextCost : .greatestFiniteMagnitude
            }
            var e = enrichments[turn.sessionId] ?? Enrichment()
            var cacheSummary = e.cacheSummary ?? SessionCacheSummary()
            recordCacheAttributionObservation(
                timestamp: turn.timestamp,
                model: turn.model,
                gitBranch: turn.gitBranch,
                isSidechain: turn.isSidechain,
                usage: turn.usage,
                summary: &cacheSummary,
                enrichment: &e
            )
            e.cacheSummary = cacheSummary
            enrichments[turn.sessionId] = e

        case .statusline(let payload, let receivedAt):
            var e = enrichments[payload.sessionId] ?? Enrichment()
            if let cost = payload.cost?.totalCostUSD { e.costUSD = cost }
            if let pct = payload.contextWindow?.usedPercentage { e.contextUsedPercentage = pct }
            if let model = payload.model?.id { e.statuslineModel = model }
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

        case .sourceHealth(let health):
            var merged = health
            if merged.lastSuccessAt == nil {
                merged.lastSuccessAt = sourceHealthByID[health.id]?.lastSuccessAt
            }
            sourceHealthByID[health.id] = merged
        }
    }

    /// Transcript usage exposes prefix totals rather than cache-block IDs, so
    /// reuse is attributed only when a later in-TTL read grows beyond the
    /// write turn's existing cached prefix by a substantial amount.
    private func recordLargeWriteEvidence(
        usage: TurnUsage,
        timestamp: Date,
        summary: inout SessionCacheSummary,
        enrichment: inout Enrichment
    ) {
        if var candidate = enrichment.latestLargeWrite,
           timestamp > candidate.createdAt {
            if timestamp < candidate.effectiveExpiresAt {
                summary.turnsAfterLastLargeWrite += 1
                let halfWriteRoundedUp = candidate.writeTokens / 2 + candidate.writeTokens % 2
                let meaningfulGrowth = max(
                    SessionCacheSummary.largeWriteMinTokens,
                    halfWriteRoundedUp
                )
                let observedGrowth = Int64(usage.cacheReadInputTokens)
                    - Int64(candidate.baselineReadTokens)
                if observedGrowth >= Int64(meaningfulGrowth) {
                    summary.lastLargeWriteReuseTurns += 1
                    candidate.effectiveExpiresAt = timestamp.addingTimeInterval(candidate.ttl.duration)
                    enrichment.latestLargeWrite = candidate
                }
            } else {
                summary.lastLargeWriteExpired = summary.lastLargeWriteReuseTurns == 0
                enrichment.latestLargeWrite = nil
            }
        }

        guard usage.cacheCreationInputTokens >= SessionCacheSummary.largeWriteMinTokens else { return }
        summary.lastLargeWriteTokens = usage.cacheCreationInputTokens
        summary.lastLargeWriteHasKnownTTL = usage.cacheTTL != nil
        summary.lastLargeWriteExpired = false
        summary.turnsAfterLastLargeWrite = 0
        summary.lastLargeWriteReuseTurns = 0
        enrichment.latestLargeWrite = nil
        guard let ttl = usage.cacheTTL else { return }
        enrichment.latestLargeWrite = LargeWriteCandidate(
            createdAt: timestamp,
            writeTokens: usage.cacheCreationInputTokens,
            baselineReadTokens: usage.cacheReadInputTokens,
            ttl: ttl,
            effectiveExpiresAt: timestamp.addingTimeInterval(ttl.duration)
        )
    }

    private func recordCacheAttributionObservation(
        timestamp: Date,
        model: String?,
        gitBranch: String?,
        isSidechain: Bool,
        usage: TurnUsage?,
        summary: inout SessionCacheSummary,
        enrichment: inout Enrichment
    ) {
        let observation = CacheAttributionObservation(
            timestamp: timestamp,
            model: model,
            gitBranch: gitBranch,
            usage: usage
        )
        if isSidechain {
            if enrichment.sidechainCacheObservations.count < Self.maxCacheAttributionObservations {
                enrichment.sidechainCacheObservations.append(observation)
            } else {
                enrichment.sidechainCacheOverflowed = true
            }
        } else {
            if enrichment.cacheAttributionObservations.count < Self.maxCacheAttributionObservations {
                enrichment.cacheAttributionObservations.append(observation)
            } else {
                enrichment.cacheAttributionOverflowed = true
            }
        }
        recomputeCacheAttribution(summary: &summary, enrichment: &enrichment)
    }

    private func replayCacheActivity(
        _ observations: [CacheAttributionObservation],
        overflowed: Bool
    ) -> (
        activity: CacheActivitySummary,
        groups: [(timestamp: Date, observation: CacheAttributionObservation?)]
    ) {
        if overflowed {
            var activity = CacheActivitySummary()
            for _ in 0..<Self.maxCacheAttributionObservations {
                activity.observe(nil)
            }
            return (activity, [])
        }

        let timestampGroups = Dictionary(grouping: observations, by: \.timestamp)
            .sorted { $0.key < $1.key }
        var activity = CacheActivitySummary()
        var reducedGroups: [(timestamp: Date, observation: CacheAttributionObservation?)] = []
        for (timestamp, timestampObservations) in timestampGroups {
            guard timestampObservations.count == 1 else {
                for _ in timestampObservations {
                    activity.observe(nil)
                }
                reducedGroups.append((timestamp, nil))
                continue
            }
            let observation = timestampObservations[0]
            let accepted = activity.observe(observation.usage)
            reducedGroups.append((timestamp, accepted ? observation : nil))
        }
        return (activity, reducedGroups)
    }

    private func recomputeCacheAttribution(
        summary: inout SessionCacheSummary,
        enrichment: inout Enrichment
    ) {
        summary.fullWarmMisses = 0
        summary.lastLargeWriteTokens = nil
        summary.lastLargeWriteHasKnownTTL = false
        summary.lastLargeWriteExpired = false
        summary.turnsAfterLastLargeWrite = 0
        summary.lastLargeWriteReuseTurns = 0
        summary.attributionIsComplete = true
        enrichment.transcriptModel = nil
        enrichment.transcriptGitBranch = nil
        enrichment.transcriptContextTokens = nil
        enrichment.transcriptLastTurnAt = nil
        enrichment.transcriptCacheEvidenceAt = nil
        enrichment.transcriptCacheTTL = nil
        enrichment.latestCompleteCacheTurnAt = nil
        enrichment.latestCompleteCacheTTL = nil
        enrichment.latestLargeWrite = nil
        enrichment.warmMisses = []
        enrichment.lastCacheMissAt = nil

        let mainReplay = replayCacheActivity(
            enrichment.cacheAttributionObservations,
            overflowed: enrichment.cacheAttributionOverflowed
        )
        let sidechainReplay = replayCacheActivity(
            enrichment.sidechainCacheObservations,
            overflowed: enrichment.sidechainCacheOverflowed
        )
        summary.main = mainReplay.activity
        summary.sidechains = sidechainReplay.activity
        summary.attributionIsComplete = !enrichment.cacheAttributionOverflowed
            && mainReplay.groups.allSatisfy { $0.observation != nil }

        guard !enrichment.cacheAttributionOverflowed else {
            return
        }

        for group in mainReplay.groups {
            let timestamp = group.timestamp
            guard let observation = group.observation,
                  let usage = observation.usage,
                  let contextTokens = usage.contextTokens
            else {
                enrichment.latestCompleteCacheTurnAt = nil
                enrichment.latestCompleteCacheTTL = nil
                enrichment.latestLargeWrite = nil
                continue
            }

            enrichment.transcriptLastTurnAt = timestamp
            enrichment.transcriptContextTokens = contextTokens
            if let model = observation.model {
                enrichment.transcriptModel = model
            }
            if let gitBranch = observation.gitBranch {
                enrichment.transcriptGitBranch = gitBranch
            }
            let hasCacheActivity = usage.cacheReadInputTokens > 0
                || usage.cacheCreationInputTokens > 0
            guard hasCacheActivity else { continue }

            enrichment.transcriptCacheEvidenceAt = timestamp
            if let ttl = usage.cacheTTL {
                enrichment.transcriptCacheTTL = ttl
            } else if usage.cacheCreationInputTokens > 0 {
                enrichment.transcriptCacheTTL = nil
            }

            recordLargeWriteEvidence(
                usage: usage,
                timestamp: timestamp,
                summary: &summary,
                enrichment: &enrichment
            )
            if let previousTurnAt = enrichment.latestCompleteCacheTurnAt,
               let previousTTL = enrichment.latestCompleteCacheTTL,
               timestamp < previousTurnAt.addingTimeInterval(previousTTL.duration),
               usage.cacheReadInputTokens == 0,
               usage.cacheCreationInputTokens >= Self.cacheMissMinRewriteTokens {
                enrichment.warmMisses.append(WarmMissEvidence(
                    previousTurnAt: previousTurnAt,
                    missAt: timestamp
                ))
            }
            enrichment.latestCompleteCacheTurnAt = timestamp
            if let ttl = usage.cacheTTL {
                enrichment.latestCompleteCacheTTL = ttl
            } else if usage.cacheCreationInputTokens > 0 {
                enrichment.latestCompleteCacheTTL = nil
            }
        }

        summary.fullWarmMisses = enrichment.warmMisses.count
        enrichment.lastCacheMissAt = enrichment.warmMisses.map(\.missAt).max()
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
        fleet.sourceHealth = SourceID.allCases.compactMap { sourceHealthByID[$0] }
        fleet.cumulativeTurnCostUSD = cumulativeTurnCostUSD
        fleet.calibration = calibration
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
            s.model = e?.statuslineModel ?? e?.transcriptModel
            s.gitBranch = e?.transcriptGitBranch
            s.contextTokens = e?.transcriptContextTokens
            s.lastTurnAt = e?.transcriptLastTurnAt
            s.cacheEvidenceAt = e?.transcriptCacheEvidenceAt
            s.cacheTTL = e?.transcriptCacheTTL
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
            s.cacheSummary = e?.cacheSummary
            return s
        }
        return fleet
    }
}
