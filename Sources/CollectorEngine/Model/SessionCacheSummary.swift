import Foundation

/// Exact token counters from assistant turns whose usage payload was complete.
/// Missing or partial usage is counted separately and never contributes implied zeros.
public struct CacheUsageSummary: Sendable, Equatable {
    public private(set) var assistantTurnCount = 0
    public private(set) var missingUsageTurnCount = 0
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var cacheReadTokens = 0
    public private(set) var cacheWriteTokens = 0
    public private(set) var cacheWrite5mTokens = 0
    public private(set) var cacheWrite1hTokens = 0
    public private(set) var unclassifiedCacheWriteTokens = 0

    public init() {}

    /// Cache-eligible tokens are reads plus writes; uncached input and output
    /// tokens are outside this ratio.
    public var cacheEligibleRatio: Double? {
        guard missingUsageTurnCount == 0 else { return nil }
        let eligible = cacheReadTokens + cacheWriteTokens
        guard eligible > 0 else { return nil }
        return Double(cacheReadTokens) / Double(eligible)
    }

    mutating func record(_ usage: TurnUsage?) {
        guard let usage, usage.isComplete else {
            missingUsageTurnCount += 1
            return
        }
        assistantTurnCount += 1
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadInputTokens
        cacheWriteTokens += usage.cacheCreationInputTokens
        cacheWrite5mTokens += usage.ephemeral5mTokens
        cacheWrite1hTokens += usage.ephemeral1hTokens
        unclassifiedCacheWriteTokens += usage.unclassifiedCacheCreationTokens
    }
}

/// Launch-replay cache evidence for one session. Main-chain and sidechain usage
/// remain separate because a subagent's cache cannot establish reuse by its parent.
public struct SessionCacheSummary: Sendable, Equatable {
    public private(set) var mainChain = CacheUsageSummary()
    public private(set) var sidechain = CacheUsageSummary()
    public private(set) var fullWarmMissCount = 0
    public private(set) var lastFullWarmMissAt: Date?
    public private(set) var largeWriteCount = 0
    public private(set) var reusedLargeWriteCount = 0
    public private(set) var outstandingLargeWriteCount = 0
    public private(set) var untrackableLargeWriteCount = 0
    /// Most recently observed main-chain write at or above 50k tokens.
    public private(set) var latestLargeWriteTokens: Int?
    /// False when the latest large write did not identify a TTL bucket.
    public private(set) var latestLargeWriteHasKnownTTL = false
    /// Effective expiry of the latest trackable write, refreshed by qualifying reads.
    public private(set) var latestLargeWriteEffectiveExpiresAt: Date?
    /// Later measured main-chain turns that conservatively reused that write.
    public private(set) var latestLargeWriteReuseTurnCount = 0

    public init() {}

    var observedAssistantTurnCount: Int {
        mainChain.assistantTurnCount
            + mainChain.missingUsageTurnCount
            + sidechain.assistantTurnCount
            + sidechain.missingUsageTurnCount
    }

    mutating func recordMainChain(_ usage: TurnUsage?) {
        mainChain.record(usage)
    }

    mutating func recordSidechain(_ usage: TurnUsage?) {
        sidechain.record(usage)
    }

    mutating func recordFullWarmMiss(at timestamp: Date) {
        fullWarmMissCount += 1
        lastFullWarmMissAt = timestamp
    }

    mutating func recordLargeWrite(tokens: Int, effectiveExpiresAt: Date?) {
        largeWriteCount += 1
        latestLargeWriteTokens = tokens
        latestLargeWriteHasKnownTTL = effectiveExpiresAt != nil
        latestLargeWriteEffectiveExpiresAt = effectiveExpiresAt
        latestLargeWriteReuseTurnCount = 0
        if effectiveExpiresAt != nil {
            outstandingLargeWriteCount += 1
        } else {
            untrackableLargeWriteCount += 1
        }
    }

    mutating func recordLatestLargeWriteReuse(effectiveExpiresAt: Date) {
        if latestLargeWriteReuseTurnCount == 0 {
            reusedLargeWriteCount += 1
            outstandingLargeWriteCount -= 1
        }
        latestLargeWriteReuseTurnCount += 1
        latestLargeWriteEffectiveExpiresAt = effectiveExpiresAt
    }
}
