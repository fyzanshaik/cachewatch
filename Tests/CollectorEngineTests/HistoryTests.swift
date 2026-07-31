import Foundation
import Testing
import CollectorEngine

@Suite
struct HistoryTests {
    let base = Date(timeIntervalSince1970: 1_785_100_000)

    func tempStore() -> QuotaHistoryStore {
        QuotaHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "cw-hist-\(UUID().uuidString).jsonl"))
    }

    func sample(at date: Date, used: Double) -> QuotaSample {
        QuotaSample(
            recordedAt: date,
            fiveHourUsedPercentage: used,
            fiveHourResetsAt: date.addingTimeInterval(3600),
            sevenDayUsedPercentage: 50,
            sevenDayResetsAt: date.addingTimeInterval(200_000),
            cumulativeTurnCostUSD: 12.5
        )
    }

    @Test
    func appendsAndLoadsSamples() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        store.append(sample(at: base, used: 10))
        store.append(sample(at: base.addingTimeInterval(60), used: 12))
        let loaded = store.load()
        #expect(loaded.count == 2, "two samples")
        #expect(loaded.first?.fiveHourUsedPercentage == 10, "first sample")
        #expect(loaded.last?.recordedAt == base.addingTimeInterval(60), "ordering")
    }

    @Test
    func pruneDropsOldEntriesAndSurvivesGarbageLines() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        store.append(sample(at: base.addingTimeInterval(-40 * 86_400), used: 5))
        store.append(sample(at: base.addingTimeInterval(-5 * 86_400), used: 7))
        try "not json\n".appendLine(to: store.fileURL)
        store.append(sample(at: base, used: 9))
        store.prune(olderThan: 30 * 86_400, now: base)
        let kept = store.load()
        #expect(kept.count == 2, "old and garbage dropped")
        #expect(kept.first?.fiveHourUsedPercentage == 7, "recent kept")
    }

    @Test
    func weeklyBurnRateProjectsExhaustionBeforeReset() {
        let reset = base.addingTimeInterval(7 * 86_400)
        let samples = [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: 5,
                fiveHourResetsAt: base.addingTimeInterval(5 * 3_600),
                sevenDayUsedPercentage: 20,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: 1
            ),
            QuotaSample(
                recordedAt: base.addingTimeInterval(4 * 3_600),
                fiveHourUsedPercentage: 25,
                fiveHourResetsAt: base.addingTimeInterval(5 * 3_600),
                sevenDayUsedPercentage: 40,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: 3
            ),
        ]

        let trend = QuotaBurnRate.derive(from: samples, window: .sevenDay)

        #expect(trend.points.map(\.usedPercentage) == [20, 40])
        #expect(trend.percentagePointsPerHour == 5)
        #expect(trend.projectedExhaustionAt == base.addingTimeInterval(16 * 3_600))
        #expect(trend.resetsAt == reset)
    }

    @Test
    func burnRateUsesSamplesAfterLatestUsageDrop() {
        let reset = base.addingTimeInterval(7 * 86_400)
        let percentages = [10.0, 60.0, 50.0, 60.0]
        let samples = percentages.enumerated().map { index, used in
            QuotaSample(
                recordedAt: base.addingTimeInterval(Double(index) * 3_600),
                fiveHourUsedPercentage: nil,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: used,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: Double(index)
            )
        }

        let trend = QuotaBurnRate.derive(from: samples, window: .sevenDay)

        #expect(trend.points.map(\.usedPercentage) == percentages)
        #expect(trend.percentagePointsPerHour == 10)
        #expect(trend.projectedExhaustionAt == base.addingTimeInterval(7 * 3_600))
    }

    @Test
    func burnRateIgnoresInvalidPercentages() {
        let reset = base.addingTimeInterval(5 * 3_600)
        let percentages = [-1.0, 20.0, 30.0, 101.0, .infinity]
        let samples = percentages.enumerated().map { index, used in
            QuotaSample(
                recordedAt: base.addingTimeInterval(Double(index) * 3_600),
                fiveHourUsedPercentage: used,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: Double(index)
            )
        }

        let trend = QuotaBurnRate.derive(from: samples, window: .fiveHour)

        #expect(trend.points.map(\.usedPercentage) == [20, 30])
        #expect(trend.percentagePointsPerHour == 10)
    }

    @Test
    func newerSampleMissingSelectedWindowPreservesItsTrend() {
        let reset = base.addingTimeInterval(7 * 86_400)
        let samples = [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: nil,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: 20,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: 1
            ),
            QuotaSample(
                recordedAt: base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: nil,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: 30,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: 2
            ),
            QuotaSample(
                recordedAt: base.addingTimeInterval(7_200),
                fiveHourUsedPercentage: 50,
                fiveHourResetsAt: base.addingTimeInterval(5 * 3_600),
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 3
            ),
        ]

        let trend = QuotaBurnRate.derive(from: samples, window: .sevenDay)

        #expect(trend.points.map(\.usedPercentage) == [20, 30])
        #expect(trend.percentagePointsPerHour == 10)
        #expect(trend.resetsAt == reset)
    }

    @Test
    func burnRateCurrentnessChangesAtResetBoundary() {
        let reset = base.addingTimeInterval(3_600)
        let trend = QuotaBurnRate.derive(from: [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: 30,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 1
            ),
        ], window: .fiveHour)

        #expect(trend.isCurrent(at: reset))
        #expect(!trend.isCurrent(at: reset.addingTimeInterval(0.001)))
    }

    @Test
    func stableUsageProducesMeasuredZeroBurn() {
        let reset = base.addingTimeInterval(7 * 86_400)
        let trend = QuotaBurnRate.derive(from: [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: nil,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: 42,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: 1
            ),
            QuotaSample(
                recordedAt: base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: nil,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: 42,
                sevenDayResetsAt: reset,
                cumulativeTurnCostUSD: 1
            ),
        ], window: .sevenDay)

        #expect(trend.percentagePointsPerHour == 0)
        #expect(trend.projectedExhaustionAt == nil)
    }

    @Test
    func missingResetIdentityDoesNotInferBurnRate() {
        let trend = QuotaBurnRate.derive(from: [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: 20,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 1
            ),
            QuotaSample(
                recordedAt: base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: 40,
                fiveHourResetsAt: nil,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 2
            ),
        ], window: .fiveHour)

        #expect(trend.points.count == 2)
        #expect(trend.percentagePointsPerHour == nil)
        #expect(trend.projectedExhaustionAt == nil)
    }

    @Test
    func duplicateTimestampsRemainInsufficientForBurnRate() {
        let reset = base.addingTimeInterval(5 * 3_600)
        let trend = QuotaBurnRate.derive(from: [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: 20,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 1
            ),
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: 40,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 2
            ),
        ], window: .fiveHour)

        #expect(trend.percentagePointsPerHour == nil)
        #expect(trend.projectedExhaustionAt == nil)
    }

    @Test
    func projectedExhaustionStopsBeingActionableAfterItPasses() {
        let reset = base.addingTimeInterval(7 * 3_600)
        let trend = QuotaBurnRate.derive(from: [
            QuotaSample(
                recordedAt: base,
                fiveHourUsedPercentage: 20,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 1
            ),
            QuotaSample(
                recordedAt: base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: 40,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 2
            ),
        ], window: .fiveHour)
        let projection = base.addingTimeInterval(4 * 3_600)

        #expect(trend.actionableProjectedExhaustion(at: projection) == projection)
        #expect(trend.actionableProjectedExhaustion(at: projection.addingTimeInterval(0.001)) == nil)
    }

    @Test
    func conflictingValuesAtTheSameTimestampAreDiscardedDeterministically() {
        let reset = base.addingTimeInterval(5 * 3_600)
        let first = QuotaSample(
            recordedAt: base,
            fiveHourUsedPercentage: 20,
            fiveHourResetsAt: reset,
            sevenDayUsedPercentage: nil,
            sevenDayResetsAt: nil,
            cumulativeTurnCostUSD: 1
        )
        let conflicting = [40.0, 60.0].map { used in
            QuotaSample(
                recordedAt: base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: used,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 2
            )
        }

        let forward = QuotaBurnRate.derive(from: [first] + conflicting, window: .fiveHour)
        let reversed = QuotaBurnRate.derive(from: [first] + conflicting.reversed(), window: .fiveHour)

        #expect(forward == reversed)
        #expect(forward.points.map(\.usedPercentage) == [20])
        #expect(forward.percentagePointsPerHour == nil)
        #expect(forward.projectedExhaustionAt == nil)
    }

    @Test
    func identicalValuesAtTheSameTimestampCollapseToOnePoint() {
        let reset = base.addingTimeInterval(5 * 3_600)
        let samples = [20.0, 40.0, 40.0].enumerated().map { index, used in
            QuotaSample(
                recordedAt: index == 0 ? base : base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: used,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: Double(index)
            )
        }

        let trend = QuotaBurnRate.derive(from: samples, window: .fiveHour)

        #expect(trend.points.map(\.usedPercentage) == [20, 40])
        #expect(trend.percentagePointsPerHour == 20)
    }

    @Test
    func conflictingResetWindowsAtTheSameTimestampAreDiscardedDeterministically() {
        let resetA = base.addingTimeInterval(5 * 3_600)
        let resetB = resetA.addingTimeInterval(5 * 3_600)
        let first = QuotaSample(
            recordedAt: base,
            fiveHourUsedPercentage: 20,
            fiveHourResetsAt: resetA,
            sevenDayUsedPercentage: nil,
            sevenDayResetsAt: nil,
            cumulativeTurnCostUSD: 1
        )
        let conflicting = [(40.0, resetA), (60.0, resetB)].map { used, reset in
            QuotaSample(
                recordedAt: base.addingTimeInterval(3_600),
                fiveHourUsedPercentage: used,
                fiveHourResetsAt: reset,
                sevenDayUsedPercentage: nil,
                sevenDayResetsAt: nil,
                cumulativeTurnCostUSD: 2
            )
        }

        let forward = QuotaBurnRate.derive(from: [first] + conflicting, window: .fiveHour)
        let reversed = QuotaBurnRate.derive(from: [first] + conflicting.reversed(), window: .fiveHour)

        #expect(forward == reversed)
        #expect(forward.points.map(\.usedPercentage) == [20])
        #expect(forward.percentagePointsPerHour == nil)
        #expect(forward.projectedExhaustionAt == nil)
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(utf8))
    }
}
