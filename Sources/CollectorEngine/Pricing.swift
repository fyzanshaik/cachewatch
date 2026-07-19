import Foundation

/// API list prices, used two ways: real dollars for API-billed sessions, and a
/// quota-weight proxy for Plan sessions. Rates change — keep in sync with
/// https://platform.claude.com/docs/en/about-claude/pricing
public enum Pricing {
    /// Base input $/MTok by model-id substring, most specific first.
    private static let baseInputPerMTok: [(match: String, rate: Double)] = [
        ("fable-5", 10.0),
        ("mythos-5", 10.0),
        ("opus-4", 5.0),
        ("sonnet-5", 3.0),
        ("sonnet-4", 3.0),
        ("haiku-4", 1.0),
    ]

    public static func baseInputRate(model: String) -> Double? {
        baseInputPerMTok.first { model.contains($0.match) }?.rate
    }

    /// Full API-price cost of one turn. Output is 5x base input across the current
    /// lineup; cache reads 0.1x; writes 1.25x (5m) / 2x (1h).
    public static func turnCostUSD(model: String, usage: TurnUsage) -> Double? {
        guard let rate = baseInputRate(model: model) else { return nil }
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
    public static func costToResume(for session: SessionSnapshot, at now: Date) -> Double? {
        guard session.cacheState(at: now) == .cold,
              let model = session.model,
              let rate = baseInputRate(model: model),
              let context = session.contextTokens,
              let ttl = session.cacheTTL
        else { return nil }
        let writeMultiplier = ttl == .oneHour ? 2.0 : 1.25
        return Double(context) / 1_000_000 * rate * writeMultiplier
    }
}
