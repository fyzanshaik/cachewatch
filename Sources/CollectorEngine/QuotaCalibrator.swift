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
    private var anchorCost: Double?
    private var anchorUsedPercentage: Double?
    private var anchorResetsAt: Date?

    /// Minimum accumulated percent before the fit is trusted.
    private static let minPercentForEstimate = 3.0
    /// Deltas below this are rounding noise (used_percentage is integer-ish live).
    private static let minPercentDelta = 0.5

    public init() {}

    public var dollarsPerPercent: Double? {
        guard totalPercent >= Self.minPercentForEstimate, totalDollars > 0 else { return nil }
        return totalDollars / totalPercent
    }

    /// 0...1 progress toward a trusted fit — for "learning quota" UI.
    public var progress: Double {
        min(1, totalPercent / Self.minPercentForEstimate)
    }

    public func percentOfWindow(forCost cost: Double) -> Double? {
        dollarsPerPercent.map { cost / $0 }
    }

    /// Anchor-based accumulation: the baseline holds still until burn since the
    /// anchor clears the noise floor, then the interval is recorded and the anchor
    /// moves. Comparing consecutive samples instead would reject steady sub-0.5%
    /// drips forever at 60s sampling.
    public mutating func observe(cumulativeCostUSD: Double, usedPercentage: Double, resetsAt: Date?) {
        guard let anchorCost, let anchorUsedPercentage, anchorResetsAt == resetsAt else {
            // First sample of a (new) window: plant the anchor.
            anchorCost = cumulativeCostUSD
            anchorUsedPercentage = usedPercentage
            anchorResetsAt = resetsAt
            return
        }
        guard usedPercentage >= anchorUsedPercentage + Self.minPercentDelta,
              cumulativeCostUSD > anchorCost
        else { return }
        totalDollars += cumulativeCostUSD - anchorCost
        totalPercent += usedPercentage - anchorUsedPercentage
        self.anchorCost = cumulativeCostUSD
        self.anchorUsedPercentage = usedPercentage
    }
}
