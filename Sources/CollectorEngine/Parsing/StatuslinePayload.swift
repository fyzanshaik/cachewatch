import Foundation

/// The JSON Claude Code pipes to the statusline command, forwarded to us by the wrapper script.
/// Everything except `session_id` is optional — the schema is undocumented and shifts across versions.
public struct StatuslinePayload: Sendable, Decodable {
    public struct Model: Sendable, Decodable {
        public let id: String?
        public let displayName: String?
    }

    public struct Cost: Sendable, Decodable {
        public let totalCostUSD: Double?
    }

    public struct ContextWindow: Sendable, Decodable {
        public let totalInputTokens: Int?
        public let totalOutputTokens: Int?
        public let contextWindowSize: Int?
        public let usedPercentage: Double?
    }

    public struct RateLimitWindow: Sendable, Decodable, Equatable {
        public let usedPercentage: Double?
        public let resetsAt: Date?
    }

    public struct RateLimits: Sendable, Decodable, Equatable {
        public let fiveHour: RateLimitWindow?
        public let sevenDay: RateLimitWindow?
    }

    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let model: Model?
    public let cost: Cost?
    public let contextWindow: ContextWindow?
    public let rateLimits: RateLimits?
    public let version: String?

    public static func decode(from data: Data) throws -> StatuslinePayload {
        try decoder.decode(StatuslinePayload.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private enum CodingKeys: String, CodingKey {
        case sessionId, transcriptPath, cwd, model, cost, contextWindow, rateLimits, version
    }

    private enum CostKeys: String, CodingKey {
        case totalCostUSD = "totalCostUsd"
    }
}

extension StatuslinePayload.Cost {
    private enum CodingKeys: String, CodingKey {
        // convertFromSnakeCase maps total_cost_usd → totalCostUsd
        case totalCostUSD = "totalCostUsd"
    }
}
