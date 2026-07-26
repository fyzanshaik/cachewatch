import Foundation

public struct ModelPrice: Sendable, Equatable {
    public let match: String
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let inputPerMTok: Double
    public let sourceURL: URL

    public init(
        match: String,
        effectiveFrom: Date,
        effectiveUntil: Date?,
        inputPerMTok: Double,
        sourceURL: URL
    ) {
        self.match = match
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.inputPerMTok = inputPerMTok
        self.sourceURL = sourceURL
    }

    fileprivate func isEffective(at timestamp: Date) -> Bool {
        guard timestamp >= effectiveFrom else { return false }
        return effectiveUntil.map { timestamp < $0 } ?? true
    }
}

public struct ResumeCostEstimate: Sendable, Equatable {
    public let costUSD: Double
    public let modelPrice: ModelPrice
    public let cacheTTL: CacheTTL
    public let cacheWriteMultiplier: Double

    public init(
        costUSD: Double,
        modelPrice: ModelPrice,
        cacheTTL: CacheTTL,
        cacheWriteMultiplier: Double
    ) {
        self.costUSD = costUSD
        self.modelPrice = modelPrice
        self.cacheTTL = cacheTTL
        self.cacheWriteMultiplier = cacheWriteMultiplier
    }
}

/// API list prices, used two ways: real dollars for API-billed sessions, and a
/// quota-weight proxy for Plan sessions. Rates change — keep in sync with
/// https://platform.claude.com/docs/en/build-with-claude/prompt-caching
public enum Pricing {
    /// 2026-09-01T00:00:00Z. Date is an absolute instant, independent of locale.
    private static let sonnet5September2026UTC = Date(
        timeIntervalSince1970: 1_788_220_800
    )
    private static let sourceURL = URL(
        string: "https://platform.claude.com/docs/en/build-with-claude/prompt-caching"
    )!

    /// Local, effective-dated API prices. Model identifiers are substring-matched;
    /// the longest matching identifier wins so a specific version beats its family.
    private static let modelPrices: [ModelPrice] = [
        allTime(match: "fable-5", rate: 10.0),
        allTime(match: "mythos-5", rate: 10.0),
        allTime(match: "opus-5", rate: 5.0),
        allTime(match: "opus-4", rate: 15.0),
        allTime(match: "opus-4-1", rate: 15.0),
        allTime(match: "opus-4-5", rate: 5.0),
        allTime(match: "opus-4-6", rate: 5.0),
        allTime(match: "opus-4-7", rate: 5.0),
        allTime(match: "opus-4-8", rate: 5.0),
        ModelPrice(
            match: "sonnet-5",
            effectiveFrom: .distantPast,
            effectiveUntil: sonnet5September2026UTC,
            inputPerMTok: 2.0,
            sourceURL: sourceURL
        ),
        ModelPrice(
            match: "sonnet-5",
            effectiveFrom: sonnet5September2026UTC,
            effectiveUntil: nil,
            inputPerMTok: 3.0,
            sourceURL: sourceURL
        ),
        allTime(match: "sonnet-4", rate: 3.0),
        allTime(match: "haiku-4", rate: 1.0),
    ]

    private static func allTime(match: String, rate: Double) -> ModelPrice {
        ModelPrice(
            match: match,
            effectiveFrom: .distantPast,
            effectiveUntil: nil,
            inputPerMTok: rate,
            sourceURL: sourceURL
        )
    }

    public static func modelPrice(model: String, at timestamp: Date) -> ModelPrice? {
        modelPrices
            .filter { model.contains($0.match) && $0.isEffective(at: timestamp) }
            .max {
                if $0.match.count != $1.match.count {
                    return $0.match.count < $1.match.count
                }
                return $0.effectiveFrom < $1.effectiveFrom
            }
    }

    public static func baseInputRate(model: String, at timestamp: Date) -> Double? {
        modelPrice(model: model, at: timestamp)?.inputPerMTok
    }

    /// Full API-price cost of one turn at its usage timestamp. Output is 5x base
    /// input across the current lineup; cache reads 0.1x; writes 1.25x (5m) /
    /// 2x (1h).
    public static func turnCostUSD(
        model: String,
        usage: TurnUsage,
        at timestamp: Date
    ) -> Double? {
        guard let rate = baseInputRate(model: model, at: timestamp) else { return nil }
        let write = Double(usage.ephemeral1hTokens) * 2.0
            + Double(usage.ephemeral5mTokens) * 1.25
            + Double(usage.cacheCreationInputTokens - usage.ephemeral1hTokens - usage.ephemeral5mTokens) * 1.25
        let weighted = Double(usage.inputTokens)
            + Double(usage.cacheReadInputTokens) * 0.1
            + max(0, write)
            + Double(usage.outputTokens) * 5.0
        return weighted / 1_000_000 * rate
    }

    /// Estimated cost of the full-context cache rewrite the next prompt to a cold
    /// session will pay. Nil while warm, or when model/context/TTL are unknown.
    public static func costToResumeEstimate(
        for session: SessionSnapshot,
        at now: Date
    ) -> ResumeCostEstimate? {
        guard session.cacheState(at: now) == .cold,
              let model = session.model,
              let price = modelPrice(model: model, at: now),
              let context = session.contextTokens,
              let ttl = session.cacheTTL
        else { return nil }
        let writeMultiplier = ttl == .oneHour ? 2.0 : 1.25
        return ResumeCostEstimate(
            costUSD: Double(context) / 1_000_000
                * price.inputPerMTok
                * writeMultiplier,
            modelPrice: price,
            cacheTTL: ttl,
            cacheWriteMultiplier: writeMultiplier
        )
    }

    public static func costToResume(for session: SessionSnapshot, at now: Date) -> Double? {
        costToResumeEstimate(for: session, at: now)?.costUSD
    }
}
