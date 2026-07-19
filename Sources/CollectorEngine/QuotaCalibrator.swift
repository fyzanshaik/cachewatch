import Foundation

/// Learns what Plan quota actually costs, passively. Anthropic doesn't publish how
/// tokens weigh against the 5-hour window, but we see both sides: cumulative
/// API-priced spend (from transcripts) and the server-reported used-% (from
/// statusline samples). Accumulating (Δdollars, Δpercent) pairs within a window
/// fits dollars-per-percent, which converts any cost estimate into "% of your 5h
/// window" — the unit that actually means something on a subscription.
public struct QuotaCalibrator: Sendable, Equatable, Codable {
    private var totalDollars = 0.0
    private var totalPercent = 0.0
    private var lastCost: Double?
    private var lastUsedPercentage: Double?
    private var lastResetsAt: Date?

    /// Minimum accumulated percent before the fit is trusted.
    private static let minPercentForEstimate = 3.0
    /// Deltas below this are rounding noise (used_percentage is integer-ish live).
    private static let minPercentDelta = 0.5

    public init() {}

    public var dollarsPerPercent: Double? {
        guard totalPercent >= Self.minPercentForEstimate, totalDollars > 0 else { return nil }
        return totalDollars / totalPercent
    }

    public func percentOfWindow(forCost cost: Double) -> Double? {
        dollarsPerPercent.map { cost / $0 }
    }

    public mutating func observe(cumulativeCostUSD: Double, usedPercentage: Double, resetsAt: Date?) {
        defer {
            lastCost = cumulativeCostUSD
            lastUsedPercentage = usedPercentage
            lastResetsAt = resetsAt
        }
        guard let lastCost, let lastUsedPercentage,
              lastResetsAt == resetsAt,  // same 5h window, else the % baseline moved
              usedPercentage > lastUsedPercentage + Self.minPercentDelta,
              cumulativeCostUSD > lastCost
        else { return }
        totalDollars += cumulativeCostUSD - lastCost
        totalPercent += usedPercentage - lastUsedPercentage
    }
}
