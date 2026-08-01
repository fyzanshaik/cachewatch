import Foundation
import Testing
import CollectorEngine

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

@Suite
struct ParsingTests {
    // MARK: - SessionRegistry

    @Test
    func decodesRegistryEntry() throws {
        let entry = try SessionRegistryEntry.decode(from: fixture("session-registry.json"))
        #expect(entry.pid == 6331, "pid")
        #expect(entry.sessionId == "df8a2ce7-cb1b-4efb-b525-c402a81af2dd", "sessionId")
        #expect(entry.cwd == "/Users/dev/workspace/atlan-clickhouse-app", "cwd")
        #expect(entry.name == "atlan-clickhouse-app-e8", "name")
        #expect(entry.status == .idle, "status")
        #expect(entry.startedAt == Date(timeIntervalSince1970: 1_784_472_863.002), "startedAt")
        #expect(entry.updatedAt == Date(timeIntervalSince1970: 1_784_486_708.811), "updatedAt")
    }

    @Test
    func unknownStatusIsTolerated() throws {
        var json = String(decoding: try fixture("session-registry.json"), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"idle\"", with: "\"someFutureStatus\"")
        let entry = try SessionRegistryEntry.decode(from: Data(json.utf8))
        #expect(entry.status == .unknown, "status")
    }

    // MARK: - Transcript

    @Test
    func parsesTurnsAndSkipsGarbage() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        #expect(turns.count == 4, "turn count")
        #expect(turns.allSatisfy { $0.sessionId == "478804ce-60a0-4507-9c5a-d2d559a813e7" }, "all sessionIds match")
    }

    @Test
    func classifiesIgnoredAndRejectedTranscriptRecords() {
        let user = #"{"type":"user","sessionId":"abc","timestamp":"2026-07-19T10:00:00Z"}"#
        let brokenAssistant = #"{"type":"assistant","sessionId":"abc"}"#

        #expect(TranscriptParser.classify(line: user) == .ignored)
        #expect(TranscriptParser.classify(line: "not-json") == .rejected)
        #expect(TranscriptParser.classify(line: brokenAssistant) == .rejected)
    }

    @Test
    func readsUsageAndTTLBuckets() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        let first = turns[0]
        #expect(first.model == "claude-opus-4-8", "model")
        #expect(first.gitBranch == "cnct-81-pulse-check-matrix", "gitBranch")
        #expect(first.usage?.cacheReadInputTokens == 251_499, "cacheRead")
        #expect(first.usage?.cacheCreationInputTokens == 1031, "cacheCreation")
        #expect(first.usage?.cacheTTL == .oneHour, "ttl")
        #expect(first.isSidechain == false, "isSidechain")

        let sidechain = turns[1]
        #expect(sidechain.isSidechain == true, "sidechain flag")
        #expect(sidechain.usage?.cacheTTL == .fiveMinutes, "sidechain ttl")
    }

    @Test
    func contextSizeIsDerivedFromLatestMainTurn() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        let latest = turns.last { !$0.isSidechain && $0.usage != nil }
        #expect(latest?.usage?.contextTokens == 255_212, "contextTokens")
    }

    @Test
    func missingUsageIsTolerated() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        #expect(turns.last?.usage == nil, "last turn has no usage")
    }

    @Test
    func partialUsageIsMarkedIncompleteForCacheSummary() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-19T18:00:00.000Z","isSidechain":false,"message":{"model":"m","usage":{"input_tokens":5,"output_tokens":1}}}
        """

        let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
        let usage = try #require(turn.usage)
        #expect(usage.isCompleteForCacheSummary == false)
    }

    @Test
    func malformedUsageIsMarkedIncompleteForCacheSummary() throws {
        let lines = [
            """
            {"type":"assistant","sessionId":"s1","timestamp":"2026-07-20T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":-1,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":0}}}
            """,
            """
            {"type":"assistant","sessionId":"s1","timestamp":"2026-07-20T10:01:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":60,"ephemeral_1h_input_tokens":20}}}}
            """,
        ]

        for line in lines {
            let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
            #expect(turn.usage?.isCompleteForCacheSummary == false)
        }
    }

    @Test
    func wrongTypedAndOverflowingUsageRemainIncompleteAssistantEvents() throws {
        let malformedUsageObjects = [
            #"{"input_tokens":"10","output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":0}"#,
            #"{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":9223372036854775808,"cache_creation_input_tokens":0}"#,
            #"{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":100,"cache_creation":"invalid"}"#,
        ]

        for (index, usageObject) in malformedUsageObjects.enumerated() {
            let line = """
            {"type":"assistant","sessionId":"s\(index)","timestamp":"2026-07-20T10:0\(index):00Z","message":{"model":"claude-opus-4-8","usage":\(usageObject)}}
            """
            let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
            let usage = try #require(turn.usage)
            #expect(usage.isCompleteForCacheSummary == false)
        }
    }

    @Test
    func wrongTypedUsageContainerRemainsAssistantEventWithoutUsage() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-20T10:00:00Z","message":{"model":"claude-opus-4-8","usage":"invalid"}}
        """

        let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
        #expect(turn.usage == nil)
    }

    @Test
    func wrongTypedMessageContainerRemainsAssistantEventWithoutUsage() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-20T10:00:00Z","message":"invalid"}
        """

        let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
        #expect(turn.usage == nil)
        #expect(turn.model == nil)
    }

    @Test
    func wrongTypedSidechainIdentityRemainsAssistantBarrierWithoutUsage() throws {
        let line = #"{"type":"assistant","sessionId":"s","timestamp":"2026-07-19T18:00:00.000Z","isSidechain":"false","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}"#

        guard case .assistant(let turn) = TranscriptParser.classify(line: line) else {
            Issue.record("Expected malformed sidechain metadata to preserve an assistant barrier")
            return
        }
        #expect(turn.isSidechain == false)
        #expect(turn.usage == nil)
    }

    @Test
    func writeWithoutTTLBucketsIsMeasuredButUnclassified() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-20T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":100000,"cache_creation_input_tokens":60000}}}
        """

        let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
        let usage = try #require(turn.usage)
        #expect(usage.isCompleteForCacheSummary)
        #expect(usage.cacheCreationInputTokens == 60_000)
        #expect(usage.unclassifiedCacheCreationTokens == 60_000)
        #expect(usage.cacheTTL == nil)
    }

    @Test
    func mixedTTLBucketsUseTheShortestTTL() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-20T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":100000,"cache_creation_input_tokens":60000,"cache_creation":{"ephemeral_5m_input_tokens":30000,"ephemeral_1h_input_tokens":30000}}}}
        """

        let turn = try #require(TranscriptParser.assistantTurns(from: Data(line.utf8)).first)
        let usage = try #require(turn.usage)
        #expect(usage.cacheTTL == .fiveMinutes)
    }

    @Test
    func turnWithoutCacheWriteHasNoTTL() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-19T18:00:00.000Z","isSidechain":false,"message":{"model":"m","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
        """
        let turns = TranscriptParser.assistantTurns(from: Data(line.utf8))
        #expect(turns.count == 1, "turn count")
        #expect(turns[0].usage?.cacheTTL == nil, "no ttl on read-only turn")
    }

    // MARK: - Statusline

    @Test
    func decodesPlanPayloadWithRateLimits() throws {
        let payload = try StatuslinePayload.decode(from: fixture("statusline-plan.json"))
        #expect(payload.sessionId == "478804ce-60a0-4507-9c5a-d2d559a813e7", "sessionId")
        #expect(payload.model?.id == "claude-opus-4-8", "model id")
        #expect(payload.cost?.totalCostUSD == 0, "cost")
        #expect(payload.contextWindow?.usedPercentage == 72.5, "context %")
        #expect(payload.rateLimits?.fiveHour?.usedPercentage == 43.0, "5h %")
        #expect(payload.rateLimits?.sevenDay?.resetsAt == ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z"), "7d reset")
    }

    @Test
    func decodesAPIPayloadWithoutRateLimits() throws {
        let payload = try StatuslinePayload.decode(from: fixture("statusline-api.json"))
        #expect(payload.rateLimits == nil, "no rate limits on API payload")
        #expect(payload.cost?.totalCostUSD == 4.8215, "cost")
    }
}
