import Foundation
import Testing
import CollectorEngine

@Suite
struct ReducerTests {
    let base = Date(timeIntervalSince1970: 1_784_500_000)

    func registryEntry(pid: Int32 = 100, sessionId: String = "sess-a") throws -> SessionRegistryEntry {
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/tmp/project","name":"project-x1","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
        """
        return try SessionRegistryEntry.decode(from: Data(json.utf8))
    }

    func mainTurn(at date: Date, ttl1h: Int = 500, sidechain: Bool = false) -> AssistantTurn {
        AssistantTurn(
            sessionId: "sess-a",
            timestamp: date,
            model: "claude-opus-4-8",
            gitBranch: "main",
            isSidechain: sidechain,
            usage: TurnUsage(
                inputTokens: 10, outputTokens: 20,
                cacheReadInputTokens: 200_000, cacheCreationInputTokens: ttl1h,
                ephemeral5mTokens: 0, ephemeral1hTokens: ttl1h
            )
        )
    }

    @Test
    func registrySnapshotPopulatesFleet() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        let fleet = reducer.snapshot
        #expect(fleet.sessions.count == 1, "session count")
        #expect(fleet.sessions.first?.sessionId == "sess-a", "sessionId")
        #expect(fleet.sessions.first?.name == "project-x1", "name")
        #expect(fleet.sessions.first?.status == .idle, "status")
    }

    @Test
    func mainTurnEnrichesSession() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        let s = reducer.snapshot.sessions[0]
        #expect(s.model == "claude-opus-4-8", "model")
        #expect(s.gitBranch == "main", "branch")
        #expect(s.contextTokens == 200_510, "context")
        #expect(s.lastTurnAt == base, "lastTurnAt")
        #expect(s.cacheTTL == .oneHour, "ttl")
    }

    @Test
    func sidechainTurnDoesNotOverwriteMainContext() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        var side = mainTurn(at: base.addingTimeInterval(60), sidechain: true)
        side = AssistantTurn(
            sessionId: side.sessionId, timestamp: side.timestamp, model: "claude-haiku-4-5-20251001",
            gitBranch: side.gitBranch, isSidechain: true,
            usage: TurnUsage(inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 100,
                             cacheCreationInputTokens: 50, ephemeral5mTokens: 50, ephemeral1hTokens: 0)
        )
        reducer.apply(.assistantTurn(side))
        let s = reducer.snapshot.sessions[0]
        #expect(s.contextTokens == 200_510, "context unchanged")
        #expect(s.model == "claude-opus-4-8", "model unchanged")
        #expect(s.cacheTTL == .oneHour, "ttl unchanged")
    }

    @Test
    func incompleteNewestUsagePreservesTrustedPointInTimeCacheState() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        let newerAt = base.addingTimeInterval(60)
        reducer.apply(.assistantTurn(AssistantTurn(
            sessionId: "sess-a",
            timestamp: newerAt,
            model: "claude-newer",
            gitBranch: "feature",
            isSidechain: false,
            usage: TurnUsage(
                inputTokens: 0,
                outputTokens: 0,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                ephemeral5mTokens: 0,
                ephemeral1hTokens: 0,
                isCompleteForCacheSummary: false
            )
        )))

        let session = reducer.snapshot.sessions[0]
        #expect(session.model == "claude-opus-4-8")
        #expect(session.gitBranch == "main")
        #expect(session.lastTurnAt == base)
        #expect(session.contextTokens == 200_510)
        #expect(session.cacheTTL == .oneHour)
        #expect(session.cacheState(at: base.addingTimeInterval(3_601)) == .cold)
    }

    @Test
    func overflowingNewestContextPreservesTrustedPointInTimeCacheState() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        let newerAt = base.addingTimeInterval(60)
        reducer.apply(.assistantTurn(AssistantTurn(
            sessionId: "sess-a",
            timestamp: newerAt,
            model: "claude-newer",
            gitBranch: "feature",
            isSidechain: false,
            usage: TurnUsage(
                inputTokens: 1,
                outputTokens: 0,
                cacheReadInputTokens: Int.max,
                cacheCreationInputTokens: 0,
                ephemeral5mTokens: 0,
                ephemeral1hTokens: 0
            )
        )))

        let session = reducer.snapshot.sessions[0]
        #expect(session.lastTurnAt == base)
        #expect(session.model == "claude-opus-4-8")
        #expect(session.gitBranch == "main")
        #expect(session.contextTokens == 200_510)
        #expect(session.cacheTTL == .oneHour)
        #expect(session.cacheSummary?.main.turnsWithCompleteUsage == 1)
        #expect(session.cacheSummary?.main.incompleteUsageTurns == 1)
        #expect(session.cacheSummary?.attributionIsComplete == false)
    }

    @Test
    func mainChainCacheSummaryAggregatesCompleteUsage() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 20,
            read: 100,
            write: 50,
            fiveMinuteWrite: 50,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(60),
            input: 20,
            output: 30,
            read: 300,
            write: 100,
            fiveMinuteWrite: 0,
            oneHourWrite: 100
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.assistantTurns == 2)
        #expect(summary.main.inputTokens == 30)
        #expect(summary.main.outputTokens == 50)
        #expect(summary.main.cacheReadTokens == 400)
        #expect(summary.main.cacheWriteTokens == 150)
        #expect(summary.main.fiveMinuteWriteTokens == 50)
        #expect(summary.main.oneHourWriteTokens == 100)
        #expect(summary.main.cacheEligibleHitRatio == 400.0 / 550.0)
        #expect(summary.sidechains.assistantTurns == 0)
    }

    @Test
    func sidechainCacheUsageIsReportedSeparately() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 20,
            read: 400,
            write: 100,
            fiveMinuteWrite: 0,
            oneHourWrite: 100
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(60),
            input: 5,
            output: 7,
            read: 20,
            write: 80,
            fiveMinuteWrite: 80,
            oneHourWrite: 0,
            sidechain: true
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.assistantTurns == 1)
        #expect(summary.main.cacheReadTokens == 400)
        #expect(summary.main.cacheWriteTokens == 100)
        #expect(summary.sidechains.assistantTurns == 1)
        #expect(summary.sidechains.cacheReadTokens == 20)
        #expect(summary.sidechains.cacheWriteTokens == 80)
        #expect(summary.sidechains.fiveMinuteWriteTokens == 80)
        #expect(summary.sidechains.evidenceQuality == .insufficient)
        #expect(summary.sidechains.cacheEligibleHitRatio == nil)
    }

    @Test
    func largeWriteReuseRequiresASubstantialLaterRead() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 0,
            write: 200_000,
            fiveMinuteWrite: 0,
            oneHourWrite: 200_000
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(60),
            input: 10,
            output: 10,
            read: 99_999,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(120),
            input: 10,
            output: 10,
            read: 100_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.lastLargeWriteTokens == 200_000)
        #expect(summary.turnsAfterLastLargeWrite == 2)
        #expect(summary.lastLargeWriteReuseTurns == 1)
    }

    @Test
    func largeWriteReuseRequiresReadGrowthBeforeTTLExpiry() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 200_000,
            write: 100_000,
            fiveMinuteWrite: 100_000,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(2 * 60),
            input: 10,
            output: 10,
            read: 220_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(5 * 60),
            input: 10,
            output: 10,
            read: 300_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.lastLargeWriteTokens == 100_000)
        #expect(summary.turnsAfterLastLargeWrite == 1)
        #expect(summary.lastLargeWriteReuseTurns == 0)
    }

    @Test
    func substantialReuseRefreshesTheEffectiveTTL() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 0,
            write: 100_000,
            fiveMinuteWrite: 100_000,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(4 * 60),
            input: 10,
            output: 10,
            read: 60_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(8 * 60),
            input: 10,
            output: 10,
            read: 60_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(14 * 60),
            input: 10,
            output: 10,
            read: 1,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.turnsAfterLastLargeWrite == 2)
        #expect(summary.lastLargeWriteReuseTurns == 2)
        #expect(!summary.lastLargeWriteExpired)
        #expect(summary.interpretation != .largeWriteNotReused)
    }

    @Test
    func cacheEvidenceDistinguishesOneTurnFromIncompleteHistory() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 100,
            write: 100,
            fiveMinuteWrite: 100,
            oneHourWrite: 0
        )))
        #expect(reducer.snapshot.sessions[0].cacheSummary?.main.evidenceQuality == .insufficient)

        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(60),
            input: 0,
            output: 0,
            read: 0,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0,
            usageIsComplete: false
        )))
        let activity = try #require(reducer.snapshot.sessions[0].cacheSummary?.main)
        #expect(activity.evidenceQuality == .incomplete)
        #expect(activity.incompleteUsageTurns == 1)
        #expect(activity.cacheEligibleHitRatio == nil)
    }

    @Test
    func strongCacheReuseIsInterpretedFromEligibleRatio() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 0,
            write: 100,
            fiveMinuteWrite: 100,
            oneHourWrite: 0
        )))
        for offset in [60.0, 120.0] {
            reducer.apply(.assistantTurn(cacheTurn(
                at: base.addingTimeInterval(offset),
                input: 10,
                output: 10,
                read: 900,
                write: 0,
                fiveMinuteWrite: 0,
                oneHourWrite: 0
            )))
        }

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.cacheEligibleHitRatio == 1_800.0 / 1_900.0)
        #expect(summary.interpretation == .strongReuse)
    }

    @Test
    func largeWriteWithoutSubstantialLaterReadIsInterpretedExplicitly() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 0,
            write: 200_000,
            fiveMinuteWrite: 0,
            oneHourWrite: 200_000
        )))
        for offset in [60.0, 120.0] {
            reducer.apply(.assistantTurn(cacheTurn(
                at: base.addingTimeInterval(offset),
                input: 10,
                output: 10,
                read: 50_000,
                write: 0,
                fiveMinuteWrite: 0,
                oneHourWrite: 0
            )))
        }

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.turnsAfterLastLargeWrite == 2)
        #expect(summary.lastLargeWriteReuseTurns == 0)
        #expect(summary.interpretation == .largeWriteNotReused)
    }

    @Test
    func turnAfterLargeWriteExpiryIsNotAReuseOpportunity() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 0,
            write: 200_000,
            fiveMinuteWrite: 200_000,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(301),
            input: 10,
            output: 10,
            read: 1,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.turnsAfterLastLargeWrite == 0)
        #expect(summary.lastLargeWriteReuseTurns == 0)
        #expect(summary.lastLargeWriteExpired)
        #expect(summary.interpretation == .largeWriteNotReused)
    }

    @Test
    func lowReuseNeedsSeveralTurnsBeforeItIsInterpreted() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        for offset in [0.0, 60.0, 120.0] {
            reducer.apply(.assistantTurn(cacheTurn(
                at: base.addingTimeInterval(offset),
                input: 10,
                output: 10,
                read: offset == 0 ? 0 : 10,
                write: 100,
                fiveMinuteWrite: 100,
                oneHourWrite: 0
            )))
        }

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.cacheEligibleHitRatio == 20.0 / 320.0)
        #expect(summary.interpretation == .limitedReuse)
    }

    @Test
    func latestLargeWriteWaitsForALaterReuseOpportunity() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        for offset in [0.0, 60.0] {
            reducer.apply(.assistantTurn(cacheTurn(
                at: base.addingTimeInterval(offset),
                input: 10,
                output: 10,
                read: 100,
                write: 0,
                fiveMinuteWrite: 0,
                oneHourWrite: 0
            )))
        }
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(120),
            input: 10,
            output: 10,
            read: 0,
            write: 200_000,
            fiveMinuteWrite: 0,
            oneHourWrite: 200_000
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.lastLargeWriteTokens == 200_000)
        #expect(summary.turnsAfterLastLargeWrite == 0)
        #expect(summary.interpretation == .awaitingLargeWriteReuse)
    }

    @Test
    func largeWriteWithoutKnownTTLIsExplicitlyUntrackable() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 100_000,
            write: 60_000,
            fiveMinuteWrite: 0,
            oneHourWrite: 0,
            unclassifiedWrite: 60_000
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(60),
            input: 10,
            output: 10,
            read: 160_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.unclassifiedWriteTokens == 60_000)
        #expect(summary.lastLargeWriteTokens == 60_000)
        #expect(summary.lastLargeWriteHasKnownTTL == false)
        #expect(summary.lastLargeWriteReuseTurns == 0)
        #expect(summary.interpretation == .largeWriteTTLUnknown)
    }

    @Test
    func unknownModelStillContributesCacheEvidence() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        for offset in [0.0, 60.0] {
            reducer.apply(.assistantTurn(cacheTurn(
                at: base.addingTimeInterval(offset),
                input: 10,
                output: 10,
                read: 300,
                write: 100,
                fiveMinuteWrite: 100,
                oneHourWrite: 0,
                model: "claude-unknown-future-model"
            )))
        }

        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.turnsWithCompleteUsage == 2)
        #expect(summary.main.cacheEligibleHitRatio == 0.75)
        #expect(reducer.snapshot.cumulativeTurnCostUSD == 0)
    }

    @Test
    func transcriptReplayBuildsSummaryBeforeRegistryArrival() throws {
        var reducer = FleetReducer()
        let turns = TranscriptParser.assistantTurns(
            from: try Data(contentsOf: fixtureURL("transcript-sample.jsonl"))
        )
        for turn in turns {
            reducer.apply(.assistantTurn(turn))
        }
        #expect(reducer.snapshot.sessions.isEmpty)

        let sessionID = try #require(turns.first?.sessionId)
        reducer.apply(.registrySnapshot([try registryEntry(sessionId: sessionID)]))
        let summary = try #require(reducer.snapshot.sessions[0].cacheSummary)
        #expect(summary.main.assistantTurns == 3)
        #expect(summary.main.turnsWithCompleteUsage == 2)
        #expect(summary.main.incompleteUsageTurns == 1)
        #expect(summary.main.cacheReadTokens == 504_499)
        #expect(summary.main.cacheWriteTokens == 3_231)
        #expect(summary.sidechains.assistantTurns == 1)
        #expect(summary.sidechains.cacheWriteTokens == 9_000)
    }

    @Test
    func outOfOrderTurnDoesNotRegressPointInTimeOrAttributionState() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        let newerAt = base.addingTimeInterval(2 * 60)
        reducer.apply(.assistantTurn(cacheTurn(
            at: newerAt,
            input: 10,
            output: 10,
            read: 0,
            write: 200_000,
            fiveMinuteWrite: 0,
            oneHourWrite: 200_000,
            model: "claude-newer"
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 20,
            output: 20,
            read: 0,
            write: 100_000,
            fiveMinuteWrite: 100_000,
            oneHourWrite: 0,
            model: "claude-older"
        )))

        let session = reducer.snapshot.sessions[0]
        let summary = try #require(session.cacheSummary)
        #expect(summary.main.assistantTurns == 2, "older turn still contributes aggregate evidence")
        #expect(summary.main.cacheWriteTokens == 300_000)
        #expect(session.lastTurnAt == newerAt)
        #expect(session.model == "claude-newer")
        #expect(session.contextTokens == 200_010)
        #expect(session.cacheTTL == .oneHour)
        #expect(summary.lastLargeWriteTokens == 200_000)
    }

    @Test
    func sameTimestampAmbiguityIsOrderIndependentAndFailsClosed() throws {
        func reduced(completeFirst: Bool) throws -> SessionSnapshot {
            var reducer = FleetReducer()
            reducer.apply(.registrySnapshot([try registryEntry()]))
            reducer.apply(.assistantTurn(cacheTurn(
                at: base,
                input: 10,
                output: 10,
                read: 100_000,
                write: 1_000,
                fiveMinuteWrite: 0,
                oneHourWrite: 1_000
            )))
            let complete = cacheTurn(
                at: base.addingTimeInterval(60),
                input: 20,
                output: 20,
                read: 0,
                write: 100_000,
                fiveMinuteWrite: 0,
                oneHourWrite: 100_000
            )
            let incomplete = AssistantTurn(
                sessionId: "sess-a",
                timestamp: base.addingTimeInterval(60),
                model: "claude-untrusted",
                gitBranch: "untrusted",
                isSidechain: false,
                usage: nil
            )
            for turn in completeFirst ? [complete, incomplete] : [incomplete, complete] {
                reducer.apply(.assistantTurn(turn))
            }
            return try #require(reducer.snapshot.sessions.first)
        }

        let completeFirst = try reduced(completeFirst: true)
        let incompleteFirst = try reduced(completeFirst: false)
        #expect(completeFirst == incompleteFirst)
        let summary = try #require(completeFirst.cacheSummary)
        #expect(summary.main.assistantTurns == 3)
        #expect(summary.main.turnsWithCompleteUsage == 1)
        #expect(summary.main.incompleteUsageTurns == 2)
        #expect(summary.attributionIsComplete == false)
        #expect(completeFirst.lastTurnAt == base)
        #expect(completeFirst.model == "claude-opus-4-8")
        #expect(completeFirst.gitBranch == "main")
    }

    @Test
    func sidechainSameTimestampAmbiguityIsOrderIndependentAndFailsClosed() throws {
        func reduced(firstRead: Int) throws -> SessionSnapshot {
            var reducer = FleetReducer()
            reducer.apply(.registrySnapshot([try registryEntry()]))
            let timestamp = base.addingTimeInterval(60)
            for read in [firstRead, 300 - firstRead] {
                reducer.apply(.assistantTurn(cacheTurn(
                    at: timestamp,
                    input: 10,
                    output: 10,
                    read: read,
                    write: 0,
                    fiveMinuteWrite: 0,
                    oneHourWrite: 0,
                    sidechain: true,
                    model: "unknown-model"
                )))
            }
            return try #require(reducer.snapshot.sessions.first)
        }

        let firstOrder = try reduced(firstRead: 100)
        let reverseOrder = try reduced(firstRead: 200)
        #expect(firstOrder == reverseOrder)
        let sidechain = try #require(firstOrder.cacheSummary?.sidechains)
        #expect(sidechain.assistantTurns == 2)
        #expect(sidechain.turnsWithCompleteUsage == 0)
        #expect(sidechain.incompleteUsageTurns == 2)
        #expect(sidechain.cacheReadTokens == 0)
    }

    @Test
    func lateIncompleteUsageRetractsAndBreaksLargeWriteReuse() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 10,
            output: 10,
            read: 0,
            write: 200_000,
            fiveMinuteWrite: 0,
            oneHourWrite: 200_000
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(10 * 60),
            input: 10,
            output: 10,
            read: 100_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))
        #expect(reducer.snapshot.sessions[0].cacheSummary?.lastLargeWriteReuseTurns == 1)

        reducer.apply(.assistantTurn(AssistantTurn(
            sessionId: "sess-a",
            timestamp: base.addingTimeInterval(5 * 60),
            model: "claude-opus-4-8",
            gitBranch: "main",
            isSidechain: false,
            usage: TurnUsage(
                inputTokens: 0,
                outputTokens: 0,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                ephemeral5mTokens: 0,
                ephemeral1hTokens: 0,
                isCompleteForCacheSummary: false
            )
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(15 * 60),
            input: 10,
            output: 10,
            read: 200_000,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        #expect(reducer.snapshot.sessions[0].cacheSummary?.lastLargeWriteReuseTurns == 0)
    }

    @Test
    func overflowingCacheAggregateBecomesIncompleteInsteadOfCrashing() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base,
            input: 0,
            output: 0,
            read: Int.max,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))
        reducer.apply(.assistantTurn(cacheTurn(
            at: base.addingTimeInterval(60),
            input: 0,
            output: 0,
            read: 1,
            write: 0,
            fiveMinuteWrite: 0,
            oneHourWrite: 0
        )))

        let activity = try #require(reducer.snapshot.sessions[0].cacheSummary?.main)
        #expect(activity.turnsWithCompleteUsage == 1)
        #expect(activity.incompleteUsageTurns == 1)
        #expect(activity.cacheReadTokens == Int.max)
        #expect(activity.cacheEligibleHitRatio == nil)
    }

    @Test
    func cacheEvidenceFailsClosedAndConvergesAfterBoundedTurnLimit() throws {
        func reduced(reverse: Bool) throws -> SessionSnapshot {
            var reducer = FleetReducer()
            reducer.apply(.registrySnapshot([try registryEntry()]))
            let offsets = reverse ? Array((0...1_024).reversed()) : Array(0...1_024)
            for offset in offsets {
                reducer.apply(.assistantTurn(cacheTurn(
                    at: base.addingTimeInterval(TimeInterval(offset)),
                    input: offset + 1,
                    output: 1,
                    read: 1,
                    write: 0,
                    fiveMinuteWrite: 0,
                    oneHourWrite: 0,
                    model: "unknown-model"
                )))
            }
            return try #require(reducer.snapshot.sessions.first)
        }

        let forward = try reduced(reverse: false)
        let reverse = try reduced(reverse: true)
        #expect(forward == reverse)
        let summary = try #require(forward.cacheSummary)
        #expect(summary.main.assistantTurns == 1_024)
        #expect(summary.main.turnsWithCompleteUsage == 0)
        #expect(summary.main.incompleteUsageTurns == 1_024)
        #expect(summary.main.inputTokens == 0)
        #expect(summary.main.evidenceQuality == .incomplete)
        #expect(summary.attributionIsComplete == false)
    }

    @Test
    func sidechainEvidenceFailsClosedAndConvergesAfterBoundedTurnLimit() throws {
        func reduced(reverse: Bool) throws -> CacheActivitySummary {
            var reducer = FleetReducer()
            reducer.apply(.registrySnapshot([try registryEntry()]))
            let offsets = reverse ? Array((0...1_024).reversed()) : Array(0...1_024)
            for offset in offsets {
                reducer.apply(.assistantTurn(cacheTurn(
                    at: base.addingTimeInterval(TimeInterval(offset)),
                    input: offset + 1,
                    output: 1,
                    read: 1,
                    write: 0,
                    fiveMinuteWrite: 0,
                    oneHourWrite: 0,
                    sidechain: true,
                    model: "unknown-model"
                )))
            }
            return try #require(reducer.snapshot.sessions.first?.cacheSummary?.sidechains)
        }

        let forward = try reduced(reverse: false)
        let reverse = try reduced(reverse: true)
        #expect(forward == reverse)
        #expect(forward.assistantTurns == 1_024)
        #expect(forward.turnsWithCompleteUsage == 0)
        #expect(forward.incompleteUsageTurns == 1_024)
        #expect(forward.inputTokens == 0)
        #expect(forward.evidenceQuality == .incomplete)
    }

    @Test
    func cacheStateWarmThenCold() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        let s = reducer.snapshot.sessions[0]
        let during = s.cacheState(at: base.addingTimeInterval(30 * 60))
        #expect(during == .warm(expiresAt: base.addingTimeInterval(60 * 60)), "warm mid-TTL")
        let after = s.cacheState(at: base.addingTimeInterval(61 * 60))
        #expect(after == .cold, "cold after TTL")
    }

    @Test
    func cacheStateUnknownWithoutTurns() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        #expect(reducer.snapshot.sessions[0].cacheState(at: base) == .unknown, "unknown")
    }

    @Test
    func statuslineEnrichesSessionAndGlobalRateLimits() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        let json = """
        {"session_id":"sess-a","cost":{"total_cost_usd":1.25},"context_window":{"used_percentage":63.0},"rate_limits":{"five_hour":{"used_percentage":40.0,"resets_at":"2026-07-20T10:00:00Z"},"seven_day":{"used_percentage":10.0,"resets_at":"2026-07-23T00:00:00Z"}}}
        """
        let payload = try StatuslinePayload.decode(from: Data(json.utf8))
        reducer.apply(.statusline(payload, receivedAt: base))
        let fleet = reducer.snapshot
        #expect(fleet.sessions[0].costUSD == 1.25, "cost")
        #expect(fleet.sessions[0].contextUsedPercentage == 63.0, "context %")
        #expect(fleet.rateLimits?.fiveHour?.usedPercentage == 40.0, "5h %")
        #expect(fleet.rateLimitsAsOf == base, "rate limits timestamp")
    }

    @Test
    func memorySampleMapsByPid() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry(pid: 4242)]))
        reducer.apply(.memorySample(pid: 4242, residentBytes: 800_000_000))
        #expect(reducer.snapshot.sessions[0].memoryBytes == 800_000_000, "memory")
    }

    @Test
    func sessionRemovedFromRegistryDisappearsButEnrichmentSurvivesReappearance() throws {
        var reducer = FleetReducer()
        reducer.apply(.registrySnapshot([try registryEntry()]))
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        reducer.apply(.registrySnapshot([]))
        #expect(reducer.snapshot.sessions.count == 0, "gone after removal")
        reducer.apply(.registrySnapshot([try registryEntry()]))
        #expect(reducer.snapshot.sessions[0].contextTokens == 200_510, "enrichment retained")
    }

    @Test
    func turnForUnknownSessionIsKeptUntilRegistryCatchesUp() throws {
        var reducer = FleetReducer()
        reducer.apply(.assistantTurn(mainTurn(at: base)))
        #expect(reducer.snapshot.sessions.count == 0, "nothing shown yet")
        reducer.apply(.registrySnapshot([try registryEntry()]))
        #expect(reducer.snapshot.sessions[0].model == "claude-opus-4-8", "turn data joined late")
    }

    private func cacheTurn(
        at date: Date,
        input: Int,
        output: Int,
        read: Int,
        write: Int,
        fiveMinuteWrite: Int,
        oneHourWrite: Int,
        unclassifiedWrite: Int = 0,
        sidechain: Bool = false,
        usageIsComplete: Bool = true,
        model: String = "claude-opus-4-8"
    ) -> AssistantTurn {
        AssistantTurn(
            sessionId: "sess-a",
            timestamp: date,
            model: model,
            gitBranch: "main",
            isSidechain: sidechain,
            usage: TurnUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: write,
                ephemeral5mTokens: fiveMinuteWrite,
                ephemeral1hTokens: oneHourWrite,
                unclassifiedCacheCreationTokens: unclassifiedWrite,
                isCompleteForCacheSummary: usageIsComplete
            )
        )
    }
}
