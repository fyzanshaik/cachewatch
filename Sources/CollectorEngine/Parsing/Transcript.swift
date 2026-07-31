import Foundation

public enum CacheTTL: Sendable, Equatable {
    case fiveMinutes
    case oneHour

    public var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        }
    }
}

public struct TurnUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let ephemeral5mTokens: Int
    public let ephemeral1hTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int,
                cacheCreationInputTokens: Int, ephemeral5mTokens: Int, ephemeral1hTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.ephemeral5mTokens = ephemeral5mTokens
        self.ephemeral1hTokens = ephemeral1hTokens
    }

    /// TTL bucket this turn's cache write landed in; nil when nothing was written.
    public var cacheTTL: CacheTTL? {
        if ephemeral1hTokens > 0 { return .oneHour }
        if ephemeral5mTokens > 0 { return .fiveMinutes }
        return nil
    }

    /// Total prompt-side tokens = the session's current context size after this turn.
    public var contextTokens: Int {
        cacheReadInputTokens + cacheCreationInputTokens + inputTokens
    }
}

/// One `type:"assistant"` line from a session transcript JSONL.
public struct AssistantTurn: Sendable, Equatable {
    public let sessionId: String
    public let timestamp: Date
    public let model: String?
    public let gitBranch: String?
    public let isSidechain: Bool
    public let usage: TurnUsage?

    public init(sessionId: String, timestamp: Date, model: String?,
                gitBranch: String?, isSidechain: Bool, usage: TurnUsage?) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.model = model
        self.gitBranch = gitBranch
        self.isSidechain = isSidechain
        self.usage = usage
    }
}

public enum TranscriptLineClassification: Sendable, Equatable {
    case assistant(AssistantTurn)
    case ignored
    case rejected
}

public enum TranscriptParser {
    /// Parses transcript JSONL bytes, skipping non-JSON and non-assistant lines.
    public static func assistantTurns(from data: Data) -> [AssistantTurn] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { assistantTurn(fromLine: String($0)) }
    }

    /// Parses a single transcript line; nil for anything that isn't a well-formed assistant turn.
    public static func assistantTurn(fromLine line: String) -> AssistantTurn? {
        guard case .assistant(let turn) = classify(line: line) else { return nil }
        return turn
    }

    public static func classify(line: String) -> TranscriptLineClassification {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(TranscriptLine.self, from: data)
        else { return .rejected }
        guard entry.type == "assistant" else { return .ignored }
        guard
              let sessionId = entry.sessionId,
              let timestamp = entry.timestamp
        else { return .rejected }

        return .assistant(AssistantTurn(
            sessionId: sessionId,
            timestamp: timestamp,
            model: entry.message?.model,
            gitBranch: entry.gitBranch,
            isSidechain: entry.isSidechain ?? false,
            usage: entry.message?.usage.map(TurnUsage.init)
        ))
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? Date(raw, strategy: fractional) { return date }
            guard let date = try? Date(raw, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unparseable timestamp: \(raw)"
                ))
            }
            return date
        }
        return d
    }()
}

private struct TranscriptLine: Decodable {
    struct Message: Decodable {
        let model: String?
        let usage: RawUsage?
    }

    struct RawUsage: Decodable {
        struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Int?
            let ephemeral_1h_input_tokens: Int?
        }

        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation: CacheCreation?
    }

    let type: String
    let sessionId: String?
    let timestamp: Date?
    let gitBranch: String?
    let isSidechain: Bool?
    let message: Message?
}

private extension TurnUsage {
    init(raw: TranscriptLine.RawUsage) {
        self.init(
            inputTokens: raw.input_tokens ?? 0,
            outputTokens: raw.output_tokens ?? 0,
            cacheReadInputTokens: raw.cache_read_input_tokens ?? 0,
            cacheCreationInputTokens: raw.cache_creation_input_tokens ?? 0,
            ephemeral5mTokens: raw.cache_creation?.ephemeral_5m_input_tokens ?? 0,
            ephemeral1hTokens: raw.cache_creation?.ephemeral_1h_input_tokens ?? 0
        )
    }
}
