import Foundation
import XCTest
@testable import CollectorEngine

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    return try Data(contentsOf: url)
}

final class SessionRegistryTests: XCTestCase {
    func testDecodesRegistryEntry() throws {
        let entry = try SessionRegistryEntry.decode(from: fixture("session-registry.json"))
        XCTAssertEqual(entry.pid, 6331)
        XCTAssertEqual(entry.sessionId, "df8a2ce7-cb1b-4efb-b525-c402a81af2dd")
        XCTAssertEqual(entry.cwd, "/Users/dev/workspace/atlan-clickhouse-app")
        XCTAssertEqual(entry.name, "atlan-clickhouse-app-e8")
        XCTAssertEqual(entry.status, .idle)
        XCTAssertEqual(entry.startedAt, Date(timeIntervalSince1970: 1_784_472_863.002))
        XCTAssertEqual(entry.updatedAt, Date(timeIntervalSince1970: 1_784_486_708.811))
    }

    func testUnknownStatusIsTolerated() throws {
        var json = String(decoding: try fixture("session-registry.json"), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"idle\"", with: "\"someFutureStatus\"")
        let entry = try SessionRegistryEntry.decode(from: Data(json.utf8))
        XCTAssertEqual(entry.status, .unknown)
    }
}

final class TranscriptTests: XCTestCase {
    func testParsesTurnsAndSkipsGarbage() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        XCTAssertEqual(turns.count, 4)
        XCTAssertTrue(turns.allSatisfy { $0.sessionId == "478804ce-60a0-4507-9c5a-d2d559a813e7" })
    }

    func testReadsUsageAndTTLBuckets() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        let first = turns[0]
        XCTAssertEqual(first.model, "claude-opus-4-8")
        XCTAssertEqual(first.gitBranch, "cnct-81-pulse-check-matrix")
        XCTAssertEqual(first.usage?.cacheReadInputTokens, 251_499)
        XCTAssertEqual(first.usage?.cacheCreationInputTokens, 1031)
        XCTAssertEqual(first.usage?.cacheTTL, .oneHour)
        XCTAssertEqual(first.isSidechain, false)

        let sidechain = turns[1]
        XCTAssertEqual(sidechain.isSidechain, true)
        XCTAssertEqual(sidechain.usage?.cacheTTL, .fiveMinutes)
    }

    func testContextSizeIsDerivedFromLatestMainTurn() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        let latest = turns.last { !$0.isSidechain && $0.usage != nil }
        XCTAssertEqual(latest?.usage?.contextTokens, 255_212)
    }

    func testMissingUsageIsTolerated() throws {
        let turns = TranscriptParser.assistantTurns(from: try fixture("transcript-sample.jsonl"))
        XCTAssertNil(turns.last?.usage)
    }

    func testTurnWithoutCacheWriteHasNoTTL() throws {
        let line = """
        {"type":"assistant","sessionId":"s","timestamp":"2026-07-19T18:00:00.000Z","isSidechain":false,"message":{"model":"m","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
        """
        let turns = TranscriptParser.assistantTurns(from: Data(line.utf8))
        XCTAssertEqual(turns.count, 1)
        XCTAssertNil(turns[0].usage?.cacheTTL)
    }
}

final class StatuslineTests: XCTestCase {
    func testDecodesPlanPayloadWithRateLimits() throws {
        let payload = try StatuslinePayload.decode(from: fixture("statusline-plan.json"))
        XCTAssertEqual(payload.sessionId, "478804ce-60a0-4507-9c5a-d2d559a813e7")
        XCTAssertEqual(payload.model?.id, "claude-opus-4-8")
        XCTAssertEqual(payload.cost?.totalCostUSD, 0)
        XCTAssertEqual(payload.contextWindow?.usedPercentage, 72.5)
        XCTAssertEqual(payload.rateLimits?.fiveHour?.usedPercentage, 43.0)
        XCTAssertEqual(payload.rateLimits?.sevenDay?.resetsAt, ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z"))
    }

    func testDecodesAPIPayloadWithoutRateLimits() throws {
        let payload = try StatuslinePayload.decode(from: fixture("statusline-api.json"))
        XCTAssertNil(payload.rateLimits)
        XCTAssertEqual(payload.cost?.totalCostUSD, 4.8215)
    }
}
