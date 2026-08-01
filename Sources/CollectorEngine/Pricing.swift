import Foundation

public struct ModelPrice: Sendable, Equatable {
    public let match: String
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let inputPerMTok: Double
    public let sourceURL: URL
}

public struct ResumeCostEstimate: Sendable, Equatable {
    public let costUSD: Double
    public let price: ModelPrice
    public let writeMultiplier: Double
}

/// API list prices, used two ways: real dollars for API-billed sessions, and a
/// quota-weight proxy for Plan sessions. Rates change — keep in sync with
/// https://platform.claude.com/docs/en/about-claude/pricing
public enum Pricing {
    public static let sourceURL = URL(
        string: "https://platform.claude.com/docs/en/about-claude/pricing"
    )!
    // 2026-09-01T00:00:00Z, the first instant after introductory pricing.
    private static let sonnet5StandardPricingStarts = Date(timeIntervalSince1970: 1_788_220_800)

    /// Effective-dated base input $/MTok by model-id substring, most specific first.
    private static let prices: [ModelPrice] = [
        ModelPrice(match: "sonnet-5", effectiveFrom: .distantPast,
                   effectiveUntil: sonnet5StandardPricingStarts, inputPerMTok: 2.0, sourceURL: sourceURL),
        ModelPrice(match: "sonnet-5", effectiveFrom: sonnet5StandardPricingStarts,
                   effectiveUntil: nil, inputPerMTok: 3.0, sourceURL: sourceURL),
        ModelPrice(match: "fable-5", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 10.0, sourceURL: sourceURL),
        ModelPrice(match: "mythos-5", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 10.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-5", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 5.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-4-8", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 5.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-4-7", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 5.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-4-6", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 5.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-4-5", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 5.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-4-1", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 15.0, sourceURL: sourceURL),
        ModelPrice(match: "opus-4", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 15.0, sourceURL: sourceURL),
        ModelPrice(match: "sonnet-4", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 3.0, sourceURL: sourceURL),
        ModelPrice(match: "haiku-4", effectiveFrom: .distantPast,
                   effectiveUntil: nil, inputPerMTok: 1.0, sourceURL: sourceURL),
    ]

    public static func modelPrice(model: String, at timestamp: Date) -> ModelPrice? {
        prices.first {
            model.contains($0.match)
                && timestamp >= $0.effectiveFrom
                && ($0.effectiveUntil.map { timestamp < $0 } ?? true)
        }
    }

    public static func baseInputRate(model: String, at timestamp: Date) -> Double? {
        modelPrice(model: model, at: timestamp)?.inputPerMTok
    }

    /// Full API-price cost of one turn. Output is 5x base input across the current
    /// lineup; cache reads 0.1x; writes 1.25x (5m) / 2x (1h).
    public static func turnCostUSD(model: String, usage: TurnUsage, at timestamp: Date) -> Double? {
        guard usage.isCompleteForCacheSummary,
              let rate = baseInputRate(model: model, at: timestamp)
        else { return nil }
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
    public static func resumeEstimate(
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
            costUSD: Double(context) / 1_000_000 * price.inputPerMTok * writeMultiplier,
            price: price,
            writeMultiplier: writeMultiplier
        )
    }

    public static func costToResume(for session: SessionSnapshot, at now: Date) -> Double? {
        resumeEstimate(for: session, at: now)?.costUSD
    }
}
