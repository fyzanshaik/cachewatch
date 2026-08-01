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
    public let unclassifiedCacheCreationTokens: Int
    private let hasCompleteCacheSummaryFields: Bool

    /// False when fields are missing, negative, or the write total does not
    /// reconcile with its TTL buckets. Numeric fallbacks remain available to
    /// legacy point-in-time calculations, but summaries exclude the turn.
    public var isCompleteForCacheSummary: Bool {
        guard hasCompleteCacheSummaryFields,
              inputTokens >= 0,
              outputTokens >= 0,
              cacheReadInputTokens >= 0,
              cacheCreationInputTokens >= 0,
              ephemeral5mTokens >= 0,
              ephemeral1hTokens >= 0,
              unclassifiedCacheCreationTokens >= 0,
              contextTokens != nil
        else { return false }
        let (classifiedTotal, classifiedOverflow) = ephemeral5mTokens.addingReportingOverflow(ephemeral1hTokens)
        let (bucketTotal, totalOverflow) = classifiedTotal.addingReportingOverflow(
            unclassifiedCacheCreationTokens
        )
        return !classifiedOverflow && !totalOverflow && bucketTotal == cacheCreationInputTokens
    }

    public init(inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int,
                cacheCreationInputTokens: Int, ephemeral5mTokens: Int, ephemeral1hTokens: Int,
                unclassifiedCacheCreationTokens: Int = 0,
                isCompleteForCacheSummary: Bool = true) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.ephemeral5mTokens = ephemeral5mTokens
        self.ephemeral1hTokens = ephemeral1hTokens
        self.unclassifiedCacheCreationTokens = unclassifiedCacheCreationTokens
        self.hasCompleteCacheSummaryFields = isCompleteForCacheSummary
    }

    /// TTL bucket this turn's cache write landed in; nil when nothing was written.
    public var cacheTTL: CacheTTL? {
        guard cacheCreationInputTokens > 0,
              unclassifiedCacheCreationTokens == 0
        else { return nil }
        if ephemeral5mTokens > 0 { return .fiveMinutes }
        if ephemeral1hTokens > 0 { return .oneHour }
        return nil
    }

    /// Total prompt-side tokens = the session's current context size after this turn.
    public var contextTokens: Int? {
        let (cachedTokens, cachedOverflow) = cacheReadInputTokens.addingReportingOverflow(
            cacheCreationInputTokens
        )
        let (totalTokens, totalOverflow) = cachedTokens.addingReportingOverflow(inputTokens)
        return cachedOverflow || totalOverflow ? nil : totalTokens
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
            usage: entry.hasMalformedIsSidechain
                ? nil
                : entry.message?.usage.map(TurnUsage.init)
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

        private enum CodingKeys: String, CodingKey {
            case model
            case usage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try? container.decode(String.self, forKey: .model)
            usage = try? container.decode(RawUsage.self, forKey: .usage)
        }
    }

    struct RawUsage: Decodable {
        struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Int?
            let ephemeral_1h_input_tokens: Int?
            let hasMalformedFields: Bool

            private enum CodingKeys: String, CodingKey {
                case ephemeral_5m_input_tokens
                case ephemeral_1h_input_tokens
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let fiveMinute = decodeLossyInt(from: container, forKey: .ephemeral_5m_input_tokens)
                let oneHour = decodeLossyInt(from: container, forKey: .ephemeral_1h_input_tokens)
                ephemeral_5m_input_tokens = fiveMinute.value
                ephemeral_1h_input_tokens = oneHour.value
                hasMalformedFields = fiveMinute.isMalformed || oneHour.isMalformed
            }
        }

        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation: CacheCreation?
        let hasMalformedFields: Bool

        private enum CodingKeys: String, CodingKey {
            case input_tokens
            case output_tokens
            case cache_read_input_tokens
            case cache_creation_input_tokens
            case cache_creation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let input = decodeLossyInt(from: container, forKey: .input_tokens)
            let output = decodeLossyInt(from: container, forKey: .output_tokens)
            let read = decodeLossyInt(from: container, forKey: .cache_read_input_tokens)
            let write = decodeLossyInt(from: container, forKey: .cache_creation_input_tokens)

            let creation: CacheCreation?
            let malformedCreation: Bool
            if !container.contains(.cache_creation)
                || ((try? container.decodeNil(forKey: .cache_creation)) == true) {
                creation = nil
                malformedCreation = false
            } else if let decoded = try? container.decode(CacheCreation.self, forKey: .cache_creation) {
                creation = decoded
                malformedCreation = decoded.hasMalformedFields
            } else {
                creation = nil
                malformedCreation = true
            }

            input_tokens = input.value
            output_tokens = output.value
            cache_read_input_tokens = read.value
            cache_creation_input_tokens = write.value
            cache_creation = creation
            hasMalformedFields = input.isMalformed
                || output.isMalformed
                || read.isMalformed
                || write.isMalformed
                || malformedCreation
        }
    }

    let type: String
    let sessionId: String?
    let timestamp: Date?
    let gitBranch: String?
    let isSidechain: Bool?
    let hasMalformedIsSidechain: Bool
    let message: Message?

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case timestamp
        case gitBranch
        case isSidechain
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        sessionId = try? container.decode(String.self, forKey: .sessionId)
        timestamp = try? container.decode(Date.self, forKey: .timestamp)
        gitBranch = try? container.decode(String.self, forKey: .gitBranch)
        if !container.contains(.isSidechain)
            || ((try? container.decodeNil(forKey: .isSidechain)) == true) {
            isSidechain = nil
            hasMalformedIsSidechain = false
        } else if let decoded = try? container.decode(Bool.self, forKey: .isSidechain) {
            isSidechain = decoded
            hasMalformedIsSidechain = false
        } else {
            isSidechain = nil
            hasMalformedIsSidechain = true
        }
        message = try? container.decode(Message.self, forKey: .message)
    }
}

private extension TurnUsage {
    init(raw: TranscriptLine.RawUsage) {
        self.init(
            inputTokens: raw.input_tokens ?? 0,
            outputTokens: raw.output_tokens ?? 0,
            cacheReadInputTokens: raw.cache_read_input_tokens ?? 0,
            cacheCreationInputTokens: raw.cache_creation_input_tokens ?? 0,
            ephemeral5mTokens: raw.cache_creation?.ephemeral_5m_input_tokens ?? 0,
            ephemeral1hTokens: raw.cache_creation?.ephemeral_1h_input_tokens ?? 0,
            unclassifiedCacheCreationTokens: raw.unclassifiedCacheCreationTokens,
            isCompleteForCacheSummary: raw.isCompleteForCacheSummary
        )
    }
}

private extension TranscriptLine.RawUsage {
    var isCompleteForCacheSummary: Bool {
        guard !hasMalformedFields,
              input_tokens != nil,
              output_tokens != nil,
              cache_read_input_tokens != nil,
              let writeTokens = cache_creation_input_tokens
        else { return false }
        return writeTokens >= 0
    }

    var unclassifiedCacheCreationTokens: Int {
        guard let writeTokens = cache_creation_input_tokens else { return 0 }
        let fiveMinute = cache_creation?.ephemeral_5m_input_tokens
        let oneHour = cache_creation?.ephemeral_1h_input_tokens
        guard fiveMinute == nil || oneHour == nil else { return 0 }
        let (classified, overflow) = (fiveMinute ?? 0).addingReportingOverflow(oneHour ?? 0)
        guard !overflow else { return -1 }
        let (unclassified, subtractionOverflow) = writeTokens.subtractingReportingOverflow(classified)
        return subtractionOverflow ? -1 : unclassified
    }
}

private func decodeLossyInt<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
) -> (value: Int?, isMalformed: Bool) {
    guard container.contains(key) else { return (nil, false) }
    if (try? container.decodeNil(forKey: key)) == true { return (nil, false) }
    do {
        return (try container.decode(Int.self, forKey: key), false)
    } catch {
        return (nil, true)
    }
}
