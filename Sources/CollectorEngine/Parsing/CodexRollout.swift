import Foundation

/// Latest observable state reconstructed from one live Codex rollout JSONL.
/// Unknown line and payload shapes are ignored field-by-field.
public struct CodexRolloutSnapshot: Sendable, Equatable {
    public let sessionId: String
    public let cwd: String
    public let version: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let status: SessionRegistryEntry.Status
    public let statusUpdatedAt: Date
    public let model: String?
    public let gitBranch: String?
    public let contextTokens: Int?
    public let contextWindowSize: Int?
    public let lastTurnAt: Date?
    public let rateLimits: StatuslinePayload.RateLimits?
    public let isUserFacing: Bool

    public var contextUsedPercentage: Double? {
        guard let contextTokens, let contextWindowSize, contextWindowSize > 0 else { return nil }
        return min(100, Double(contextTokens) / Double(contextWindowSize) * 100)
    }

    public func registryEntry(pid: Int32) -> SessionRegistryEntry {
        SessionRegistryEntry(
            pid: pid,
            sessionId: sessionId,
            provider: .codex,
            cwd: cwd,
            name: URL(fileURLWithPath: cwd).lastPathComponent,
            version: version,
            status: status,
            startedAt: startedAt,
            updatedAt: updatedAt,
            statusUpdatedAt: statusUpdatedAt
        )
    }
}

public enum CodexRolloutParser {
    public static func snapshot(from data: Data) -> CodexRolloutSnapshot? {
        var accumulator = CodexRolloutAccumulator()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            accumulator.consume(line: String(line))
        }
        return accumulator.snapshot
    }
}

struct CodexRolloutAccumulator {
    private var sessionId: String?
    private var cwd: String?
    private var version: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var status: SessionRegistryEntry.Status = .idle
    private var statusUpdatedAt: Date?
    private var model: String?
    private var gitBranch: String?
    private var contextTokens: Int?
    private var contextWindowSize: Int?
    private var lastTurnAt: Date?
    private var rateLimits: StatuslinePayload.RateLimits?
    private var isUserFacing = true

    mutating func consume(line: String) {
        guard let data = line.data(using: .utf8),
              let line = try? CodexJSON.decoder.decode(CodexLine.self, from: data)
        else { return }

        updatedAt = max(updatedAt ?? line.timestamp, line.timestamp)
        switch line.type {
        case "session_meta":
            if let id = line.payload.id ?? line.payload.sessionId { sessionId = id }
            if let value = line.payload.cwd { cwd = value }
            if let value = line.payload.cliVersion { version = value }
            if let value = line.payload.git?.branch { gitBranch = value }
            if startedAt == nil { startedAt = line.timestamp }
            if statusUpdatedAt == nil { statusUpdatedAt = line.timestamp }
            if line.payload.threadSource?.isUserFacing == false { isUserFacing = false }

        case "turn_context":
            if let value = line.payload.cwd { cwd = value }
            if let value = line.payload.model { model = value }

        case "event_msg":
            switch line.payload.type {
            case "task_started":
                status = .busy
                statusUpdatedAt = line.timestamp
                if let size = line.payload.modelContextWindow { contextWindowSize = size }
            case "task_complete", "turn_aborted":
                status = .idle
                statusUpdatedAt = line.timestamp
            case "token_count":
                if let tokens = line.payload.info?.lastTokenUsage?.inputTokens {
                    contextTokens = tokens
                }
                if let size = line.payload.info?.modelContextWindow {
                    contextWindowSize = size
                }
                lastTurnAt = line.timestamp
                if let limits = line.payload.rateLimits {
                    rateLimits = limits.normalized
                }
            default:
                break
            }

        default:
            break
        }
    }

    var snapshot: CodexRolloutSnapshot? {
        guard let sessionId, let cwd, let startedAt else { return nil }
        return CodexRolloutSnapshot(
            sessionId: sessionId,
            cwd: cwd,
            version: version,
            startedAt: startedAt,
            updatedAt: updatedAt ?? startedAt,
            status: status,
            statusUpdatedAt: statusUpdatedAt ?? startedAt,
            model: model,
            gitBranch: gitBranch,
            contextTokens: contextTokens,
            contextWindowSize: contextWindowSize,
            lastTurnAt: lastTurnAt,
            rateLimits: rateLimits,
            isUserFacing: isUserFacing
        )
    }
}

private struct CodexLine: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let sessionId: String?
        let cwd: String?
        let cliVersion: String?
        let threadSource: ThreadSource?
        let git: Git?
        let model: String?
        let modelContextWindow: Int?
        let info: TokenInfo?
        let rateLimits: RawRateLimits?
    }

    struct Git: Decodable {
        let branch: String?
    }

    struct TokenInfo: Decodable {
        let lastTokenUsage: TokenUsage?
        let modelContextWindow: Int?
    }

    struct TokenUsage: Decodable {
        let inputTokens: Int?
    }

    enum ThreadSource: Decodable, Equatable {
        case userFacing
        case subagent

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self = value == "subagent" ? .subagent : .userFacing
            } else {
                // Current subagents use an object payload. Keep unknown string
                // variants visible, but exclude the unambiguously nested shape.
                self = .subagent
            }
        }

        var isUserFacing: Bool {
            self == .userFacing
        }
    }

    struct RawRateLimits: Decodable {
        let primary: RawWindow?
        let secondary: RawWindow?

        var normalized: StatuslinePayload.RateLimits? {
            var fiveHour: StatuslinePayload.RateLimitWindow?
            var sevenDay: StatuslinePayload.RateLimitWindow?
            for window in [primary, secondary].compactMap({ $0 }) {
                guard let minutes = window.windowMinutes else { continue }
                let normalized = StatuslinePayload.RateLimitWindow(
                    usedPercentage: window.usedPercent,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
                )
                if minutes <= 360 {
                    fiveHour = normalized
                } else if minutes >= 6 * 24 * 60 {
                    sevenDay = normalized
                }
            }
            guard fiveHour != nil || sevenDay != nil else { return nil }
            return StatuslinePayload.RateLimits(fiveHour: fiveHour, sevenDay: sevenDay)
        }
    }

    struct RawWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Double?
    }
}

private enum CodexJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(raw, strategy: .iso8601) { return date }
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable Codex timestamp: \(raw)"
            ))
        }
        return decoder
    }()
}
