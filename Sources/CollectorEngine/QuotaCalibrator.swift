import Foundation

/// Learns what Plan quota actually costs, passively. Anthropic doesn't publish how
/// tokens weigh against the 5-hour window, but we see both sides: cumulative
/// API-priced spend (from transcripts) and the server-reported used-% (from
/// statusline samples). Accumulating (Δdollars, Δpercent) pairs within a window
/// fits dollars-per-percent, which converts any cost estimate into "% of your 5h
/// window" — the unit that actually means something on a subscription.
public struct QuotaCalibrator: Sendable, Equatable, Codable {
    private var intervalRatios: [Double] = []
    private var totalPercent = 0.0
    private var anchorCost: Double?
    private var anchorUsedPercentage: Double?
    private var anchorResetsAt: Date?

    /// Minimum accumulated percent before the fit is trusted.
    private static let minPercentForEstimate = 3.0
    /// Deltas below this are rounding noise (used_percentage is integer-ish live).
    private static let minPercentDelta = 0.5
    /// Intervals with less local spend than this are dominated by burn Cachewatch
    /// can't see (claude.ai, other devices) and would poison the fit.
    private static let minDollarsPerInterval = 0.25
    private static let maxIntervals = 200

    public init() {}

    /// Median of per-interval dollars-per-percent. Robust: an interval
    /// contaminated by external quota burn (claude.ai, other machines, probes)
    /// shifts one sample, not the estimate.
    public var dollarsPerPercent: Double? {
        guard totalPercent >= Self.minPercentForEstimate, !intervalRatios.isEmpty else { return nil }
        let sorted = intervalRatios.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// 0...1 progress toward a trusted fit — for "learning quota" UI.
    public var progress: Double {
        min(1, totalPercent / Self.minPercentForEstimate)
    }

    public func percentOfWindow(forCost cost: Double) -> Double? {
        dollarsPerPercent.map { cost / $0 }
    }

    /// Anchor-based accumulation: the baseline holds still until burn since the
    /// anchor clears both noise floors, then the interval is recorded and the
    /// anchor moves. Comparing consecutive samples instead would reject steady
    /// sub-0.5% drips forever at 60s sampling.
    public mutating func observe(cumulativeCostUSD: Double, usedPercentage: Double, resetsAt: Date?) {
        guard let anchorCost, let anchorUsedPercentage, anchorResetsAt == resetsAt else {
            // First sample of a (new) window: plant the anchor.
            anchorCost = cumulativeCostUSD
            anchorUsedPercentage = usedPercentage
            anchorResetsAt = resetsAt
            return
        }
        let dollars = cumulativeCostUSD - anchorCost
        let percent = usedPercentage - anchorUsedPercentage
        guard percent >= Self.minPercentDelta, dollars >= Self.minDollarsPerInterval else { return }
        intervalRatios.append(dollars / percent)
        if intervalRatios.count > Self.maxIntervals {
            intervalRatios.removeFirst(intervalRatios.count - Self.maxIntervals)
        }
        totalPercent += percent
        self.anchorCost = cumulativeCostUSD
        self.anchorUsedPercentage = usedPercentage
    }
}
