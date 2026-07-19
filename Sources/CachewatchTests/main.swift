import Foundation
import CollectorEngine

let t = TestKit()

// MARK: - SessionRegistry

t.run("decodesRegistryEntry") { t in
    let entry = try SessionRegistryEntry.decode(from: fixture("session-registry.json"))
    t.expectEqual(entry.pid, 6331, "pid")
    t.expectEqual(entry.sessionId, "df8a2ce7-cb1b-4efb-b525-c402a81af2dd", "sessionId")
    t.expectEqual(entry.cwd, "/Users/dev/workspace/atlan-clickhouse-app", "cwd")
    t.expectEqual(entry.name, "atlan-clickhouse-app-e8", "name")
    t.expectEqual(entry.status, .idle, "status")
    t.expectEqual(entry.startedAt, Date(timeIntervalSince1970: 1_784_472_863.002), "startedAt")
    t.expectEqual(entry.updatedAt, Date(timeIntervalSince1970: 1_784_486_708.811), "updatedAt")
}

t.run("unknownStatusIsTolerated") { t in
    var json = String(decoding: try fixture("session-registry.json"), as: UTF8.self)
    json = json.replacingOccurrences(of: "\"idle\"", with: "\"someFutureStatus\"")
    let entry = try SessionRegistryEntry.decode(from: Data(json.utf8))
    t.expectEqual(entry.status, .unknown, "status")
}

// MARK: - Transcript

t.run("parsesTurnsAndSkipsGarbage") { t in
    let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
    t.expectEqual(turns.count, 4, "turn count")
    t.expect(turns.allSatisfy { $0.sessionId == "478804ce-60a0-4507-9c5a-d2d559a813e7" }, "all sessionIds match")
}

t.run("readsUsageAndTTLBuckets") { t in
    let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
    let first = turns[0]
    t.expectEqual(first.model, "claude-opus-4-8", "model")
    t.expectEqual(first.gitBranch, "cnct-81-pulse-check-matrix", "gitBranch")
    t.expectEqual(first.usage?.cacheReadInputTokens, 251_499, "cacheRead")
    t.expectEqual(first.usage?.cacheCreationInputTokens, 1031, "cacheCreation")
    t.expectEqual(first.usage?.cacheTTL, .oneHour, "ttl")
    t.expectEqual(first.isSidechain, false, "isSidechain")

    let sidechain = turns[1]
    t.expectEqual(sidechain.isSidechain, true, "sidechain flag")
    t.expectEqual(sidechain.usage?.cacheTTL, .fiveMinutes, "sidechain ttl")
}

t.run("contextSizeIsDerivedFromLatestMainTurn") { t in
    let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
    let latest = turns.last { !$0.isSidechain && $0.usage != nil }
    t.expectEqual(latest?.usage?.contextTokens, 255_212, "contextTokens")
}

t.run("missingUsageIsTolerated") { t in
    let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
    t.expect(turns.last?.usage == nil, "last turn has no usage")
}

t.run("turnWithoutCacheWriteHasNoTTL") { t in
    let line = """
    {"type":"assistant","sessionId":"s","timestamp":"2026-07-19T18:00:00.000Z","isSidechain":false,"message":{"model":"m","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
    """
    let turns = TranscriptParser.assistantTurns(from: Data(line.utf8))
    t.expectEqual(turns.count, 1, "turn count")
    t.expect(turns[0].usage?.cacheTTL == nil, "no ttl on read-only turn")
}

// MARK: - Statusline

t.run("decodesPlanPayloadWithRateLimits") { t in
    let payload = try StatuslinePayload.decode(from: fixture("statusline-plan.json"))
    t.expectEqual(payload.sessionId, "478804ce-60a0-4507-9c5a-d2d559a813e7", "sessionId")
    t.expectEqual(payload.model?.id, "claude-opus-4-8", "model id")
    t.expectEqual(payload.cost?.totalCostUSD, 0, "cost")
    t.expectEqual(payload.contextWindow?.usedPercentage, 72.5, "context %")
    t.expectEqual(payload.rateLimits?.fiveHour?.usedPercentage, 43.0, "5h %")
    t.expectEqual(payload.rateLimits?.sevenDay?.resetsAt, ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z"), "7d reset")
}

t.run("decodesAPIPayloadWithoutRateLimits") { t in
    let payload = try StatuslinePayload.decode(from: fixture("statusline-api.json"))
    t.expect(payload.rateLimits == nil, "no rate limits on API payload")
    t.expectEqual(payload.cost?.totalCostUSD, 4.8215, "cost")
}

// MARK: - Reducer

runReducerTests(t)

// MARK: - Sources

runSourceTests(t)

t.finish()
