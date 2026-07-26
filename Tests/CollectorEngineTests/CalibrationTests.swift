import Foundation
import Testing
import CollectorEngine

@Suite
struct CalibrationTests {
    let base = Date(timeIntervalSince1970: 1_785_000_000)
    var window1: Date { base.addingTimeInterval(3600) }
    var window2: Date { base.addingTimeInterval(3600 + 18_000) }

    @Test
    func turnCostWeighsTokenTypes() throws {
        // opus 4.8 ($5 base): 100k reads at 0.1x = $0.05, 10k 1h-writes at 2x = $0.10,
        // 100 raw input = $0.0005, 1k output at 5x = $0.025
        let usage = TurnUsage(
            inputTokens: 100, outputTokens: 1000,
            cacheReadInputTokens: 100_000, cacheCreationInputTokens: 10_000,
            ephemeral5mTokens: 0, ephemeral1hTokens: 10_000
        )
        let cost = Pricing.turnCostUSD(model: "claude-opus-4-8", usage: usage, at: base)
        #expect(abs((cost ?? 0) - 0.1755) < 0.0001, "weighted cost, got \(String(describing: cost))")
        #expect(Pricing.turnCostUSD(model: "unknown-model", usage: usage, at: base) == nil, "unknown model")
    }

    @Test
    func calibratorFitsDollarsPerPercent() throws {
        var cal = QuotaCalibrator()
        #expect(cal.dollarsPerPercent == nil, "starts unknown")
        // Three samples in one window: $2 spent per 1% consistently.
        cal.observe(cumulativeCostUSD: 10, usedPercentage: 40, resetsAt: window1)
        cal.observe(cumulativeCostUSD: 14, usedPercentage: 42, resetsAt: window1)
        cal.observe(cumulativeCostUSD: 20, usedPercentage: 45, resetsAt: window1)
        #expect(cal.dollarsPerPercent.map { abs($0 - 2.0) < 0.001 } == true, "fits $2/percent, got \(String(describing: cal.dollarsPerPercent))")
        #expect(cal.percentOfWindow(forCost: 8.0).map { Int($0.rounded()) } == 4, "converts cost to percent")
    }

    @Test
    func calibratorIgnoresWindowBoundariesAndNoise() throws {
        var cal = QuotaCalibrator()
        cal.observe(cumulativeCostUSD: 10, usedPercentage: 90, resetsAt: window1)
        // New window: percentage plummets — must not record a negative delta.
        cal.observe(cumulativeCostUSD: 12, usedPercentage: 1, resetsAt: window2)
        #expect(cal.dollarsPerPercent == nil, "cross-window pair rejected")
        // Tiny deltas below noise floor are skipped.
        cal.observe(cumulativeCostUSD: 12.01, usedPercentage: 1.1, resetsAt: window2)
        #expect(cal.dollarsPerPercent == nil, "sub-threshold delta rejected")
        // Real accumulation works within window2.
        cal.observe(cumulativeCostUSD: 18, usedPercentage: 4, resetsAt: window2)
        cal.observe(cumulativeCostUSD: 24, usedPercentage: 7, resetsAt: window2)
        #expect(cal.dollarsPerPercent != nil, "fits within new window")
    }

    @Test
    func calibratorPersistsThroughAppState() throws {
        var cal = QuotaCalibrator()
        cal.observe(cumulativeCostUSD: 0, usedPercentage: 10, resetsAt: window1)
        cal.observe(cumulativeCostUSD: 12, usedPercentage: 16, resetsAt: window1)
        var state = AppState()
        state.calibration = cal
        let restored = try AppState.decode(from: state.encoded())
        #expect(restored.calibration?.dollarsPerPercent == cal.dollarsPerPercent, "estimate survives round trip")
    }

    @Test
    func reducerAccumulatesFleetCost() throws {
        var reducer = FleetReducer()
        let turn = AssistantTurn(
            sessionId: "any", timestamp: base, model: "claude-opus-4-8",
            gitBranch: nil, isSidechain: false,
            usage: TurnUsage(inputTokens: 0, outputTokens: 0,
                             cacheReadInputTokens: 1_000_000, cacheCreationInputTokens: 0,
                             ephemeral5mTokens: 0, ephemeral1hTokens: 0)
        )
        reducer.apply(.assistantTurn(turn))  // 1M reads on opus = $0.50
        let sidechain = AssistantTurn(
            sessionId: "any", timestamp: base, model: "claude-haiku-4-5-20251001",
            gitBranch: nil, isSidechain: true,
            usage: TurnUsage(inputTokens: 1_000_000, outputTokens: 0,
                             cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
                             ephemeral5mTokens: 0, ephemeral1hTokens: 0)
        )
        reducer.apply(.assistantTurn(sidechain))  // sidechains count: 1M input on haiku = $1
        #expect(abs(reducer.snapshot.cumulativeTurnCostUSD - 1.5) < 0.0001, "fleet cost accumulates, got \(reducer.snapshot.cumulativeTurnCostUSD)")
    }
}
