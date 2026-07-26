import Foundation
import Testing
import CollectorEngine

@Suite
struct SessionCacheSummaryTests {
    let base = Date(timeIntervalSince1970: 1_784_900_000)

    func registryEntry() throws -> SessionRegistryEntry {
        try SessionRegistryEntry.decode(from: Data("""
        {"pid":1,"sessionId":"sess-a","cwd":"/tmp","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
        """.utf8))
    }

    func turn(
        minutes: Double,
        model: String? = "claude-opus-4-8",
        sidechain: Bool = false,
        input: Int = 10,
        output: Int = 20,
        read: Int,
        write5m: Int = 0,
        write1h: Int = 0,
        unclassifiedWrite: Int = 0
    ) -> AssistantTurn {
        AssistantTurn(
            sessionId: "sess-a",
            timestamp: base.addingTimeInterval(minutes * 60),
            model: model,
            gitBranch: "main",
            isSidechain: sidechain,
            usage: TurnUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: write5m + write1h + unclassifiedWrite,
                ephemeral5mTokens: write5m,
                ephemeral1hTokens: write1h
            )
        )
    }

    func snapshot(after turns: [AssistantTurn]) throws -> SessionSnapshot {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        for turn in turns {
            reducer.apply(.assistantTurn(turn))
        }
        return reducer.snapshot.sessions[0]
    }

    @Test
    func aggregatesMeasuredMainChainUsageAndTTLBuckets() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, input: 11, output: 21, read: 80_000, write5m: 4_000),
            turn(minutes: 1, input: 12, output: 22, read: 120_000, write1h: 6_000),
            turn(minutes: 2, input: 13, output: 23, read: 0, unclassifiedWrite: 7_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.mainChain.assistantTurnCount == 3)
        #expect(summary.mainChain.missingUsageTurnCount == 0)
        #expect(summary.mainChain.inputTokens == 36)
        #expect(summary.mainChain.outputTokens == 66)
        #expect(summary.mainChain.cacheReadTokens == 200_000)
        #expect(summary.mainChain.cacheWriteTokens == 17_000)
        #expect(summary.mainChain.cacheWrite5mTokens == 4_000)
        #expect(summary.mainChain.cacheWrite1hTokens == 6_000)
        #expect(summary.mainChain.unclassifiedCacheWriteTokens == 7_000)
        #expect(summary.mainChain.cacheEligibleRatio == 200_000.0 / 217_000.0)
    }

    @Test
    func countsFullWarmMissesWithoutTreatingExpiredRewritesAsMisses() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, read: 200_000, write1h: 1_000),
            turn(minutes: 10, read: 0, write1h: 201_000),
            turn(minutes: 130, read: 0, write1h: 220_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.fullWarmMissCount == 1)
        #expect(summary.lastFullWarmMissAt == base.addingTimeInterval(10 * 60))
        #expect(session.lastCacheMissAt == summary.lastFullWarmMissAt)
    }

    @Test
    func largeWriteRequiresAProportionalReadIncreaseWithinItsTTL() throws {
        let reused = try snapshot(after: [
            turn(minutes: 0, read: 200_000, write1h: 100_000),
            turn(minutes: 10, read: 250_000),
        ])
        let reusedSummary = try #require(reused.cacheSummary)
        #expect(reusedSummary.largeWriteCount == 1)
        #expect(reusedSummary.reusedLargeWriteCount == 1)
        #expect(reusedSummary.outstandingLargeWriteCount == 0)

        let notAttributed = try snapshot(after: [
            turn(minutes: 0, read: 200_000, write5m: 100_000),
            // A large read alone is not attribution: it did not grow enough over
            // the write turn's already-cached prefix.
            turn(minutes: 2, read: 220_000),
            // Enough growth exactly at expiry is cold, not inside the 5m TTL.
            turn(minutes: 5, read: 300_000),
        ])
        let outstandingSummary = try #require(notAttributed.cacheSummary)
        #expect(outstandingSummary.largeWriteCount == 1)
        #expect(outstandingSummary.reusedLargeWriteCount == 0)
        #expect(outstandingSummary.outstandingLargeWriteCount == 1)
    }

    @Test
    func latestLargeWriteCountsLaterReuseAndRefreshesItsTTL() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, read: 100_000, write5m: 60_000),
            turn(minutes: 4, read: 160_000),
            // Past the original expiry, but inside the TTL refreshed at minute 4.
            turn(minutes: 8, read: 165_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.latestLargeWriteTokens == 60_000)
        #expect(summary.latestLargeWriteReuseTurnCount == 2)
        #expect(summary.latestLargeWriteEffectiveExpiresAt == base.addingTimeInterval(13 * 60))
        #expect(summary.reusedLargeWriteCount == 1, "a reused write is counted once")
        #expect(summary.outstandingLargeWriteCount == 0)
    }

    @Test
    func oneReadCannotConfirmMultipleSupersededLargeWrites() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, read: 100_000, write1h: 60_000),
            turn(minutes: 1, read: 100_000, write1h: 80_000),
            turn(minutes: 2, read: 180_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.largeWriteCount == 2)
        #expect(summary.reusedLargeWriteCount == 1)
        #expect(summary.outstandingLargeWriteCount == 1)
        #expect(summary.latestLargeWriteTokens == 80_000)
        #expect(summary.latestLargeWriteReuseTurnCount == 1)
    }

    @Test
    func largeWriteWithoutKnownTTLIsExplicitlyUntrackable() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, read: 100_000, unclassifiedWrite: 60_000),
            turn(minutes: 1, read: 160_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.largeWriteCount == 1)
        #expect(summary.untrackableLargeWriteCount == 1)
        #expect(summary.outstandingLargeWriteCount == 0)
        #expect(summary.reusedLargeWriteCount == 0)
        #expect(summary.latestLargeWriteHasKnownTTL == false)
    }

    @Test
    func sidechainUsageIsReportedSeparatelyAndNeverMixedIntoMainChain() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, read: 100_000, write1h: 5_000),
            turn(
                minutes: 1,
                sidechain: true,
                input: 1_000,
                output: 2_000,
                read: 300_000,
                write5m: 60_000
            ),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.mainChain.assistantTurnCount == 1)
        #expect(summary.mainChain.inputTokens == 10)
        #expect(summary.mainChain.cacheReadTokens == 100_000)
        #expect(summary.mainChain.cacheWriteTokens == 5_000)
        #expect(summary.sidechain.assistantTurnCount == 1)
        #expect(summary.sidechain.inputTokens == 1_000)
        #expect(summary.sidechain.outputTokens == 2_000)
        #expect(summary.sidechain.cacheReadTokens == 300_000)
        #expect(summary.sidechain.cacheWrite5mTokens == 60_000)
        #expect(summary.largeWriteCount == 0, "sidechain writes are not main-chain candidates")
    }

    @Test
    func missingUsageIsExplicitAndDoesNotAddFalseZeroMeasurements() throws {
        let missingMain = AssistantTurn(
            sessionId: "sess-a",
            timestamp: base.addingTimeInterval(60),
            model: "claude-opus-4-8",
            gitBranch: "main",
            isSidechain: false,
            usage: nil
        )
        let missingSidechain = AssistantTurn(
            sessionId: "sess-a",
            timestamp: base.addingTimeInterval(120),
            model: "claude-haiku-4-5-20251001",
            gitBranch: "main",
            isSidechain: true,
            usage: nil
        )
        let session = try snapshot(after: [
            turn(minutes: 0, input: 7, output: 8, read: 100, write1h: 10),
            missingMain,
            missingSidechain,
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.mainChain.assistantTurnCount == 1)
        #expect(summary.mainChain.missingUsageTurnCount == 1)
        #expect(summary.mainChain.inputTokens == 7)
        #expect(summary.mainChain.outputTokens == 8)
        #expect(summary.mainChain.cacheReadTokens == 100)
        #expect(summary.mainChain.cacheWriteTokens == 10)
        #expect(summary.mainChain.cacheEligibleRatio == nil, "coverage gap makes the aggregate ratio unknown")
        #expect(summary.sidechain.assistantTurnCount == 0)
        #expect(summary.sidechain.missingUsageTurnCount == 1)
    }

    @Test
    func incompleteUsageBreaksWarmMissAttribution() throws {
        let incomplete = AssistantTurn(
            sessionId: "sess-a",
            timestamp: base.addingTimeInterval(5 * 60),
            model: "claude-opus-4-8",
            gitBranch: "main",
            isSidechain: false,
            usage: TurnUsage(
                inputTokens: 10,
                outputTokens: 20,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                ephemeral5mTokens: 0,
                ephemeral1hTokens: 0,
                isComplete: false
            )
        )
        let session = try snapshot(after: [
            turn(minutes: 0, read: 200_000, write1h: 1_000),
            incomplete,
            turn(minutes: 10, read: 0, write1h: 201_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.mainChain.missingUsageTurnCount == 1)
        #expect(summary.fullWarmMissCount == 0, "unknown intervening cache state prevents false attribution")
        #expect(session.lastCacheMissAt == nil)
    }

    @Test
    func unknownModelDoesNotSuppressTokenOrCacheEvidence() throws {
        let session = try snapshot(after: [
            turn(minutes: 0, model: "claude-future-unknown", read: 90_000, write1h: 10_000),
            turn(minutes: 1, model: nil, read: 100_000),
        ])
        let summary = try #require(session.cacheSummary)

        #expect(summary.mainChain.assistantTurnCount == 2)
        #expect(summary.mainChain.cacheReadTokens == 190_000)
        #expect(summary.mainChain.cacheWriteTokens == 10_000)
        #expect(summary.mainChain.cacheEligibleRatio == 0.95)
    }

    @Test
    func turnEvidenceWaitsForRegistryAndJoinsWhenSessionAppears() throws {
        var reducer = FleetReducer()
        reducer.apply(.assistantTurn(turn(minutes: 0, read: 100_000, write1h: 60_000)))
        reducer.apply(.assistantTurn(turn(minutes: 1, read: 160_000)))
        #expect(reducer.snapshot.sessions.isEmpty)

        reducer.apply(.registrySnapshot([try registryEntry()]))
        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.mainChain.assistantTurnCount == 2)
        #expect(summary.mainChain.cacheReadTokens == 260_000)
        #expect(summary.reusedLargeWriteCount == 1, "launch replay is summarized before registry catches up")
    }
}
