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

    public struct RateLimitWindow: Sendable, Codable, Equatable {
        public let usedPercentage: Double?
        public let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case usedPercentage, resetsAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = try c.decodeIfPresent(Double.self, forKey: .usedPercentage)
            // Observed live as epoch seconds; docs-era captures showed ISO strings. Accept both.
            if let epoch = try? c.decodeIfPresent(Double.self, forKey: .resetsAt) {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let iso = try? c.decodeIfPresent(String.self, forKey: .resetsAt) {
                resetsAt = try? Date(iso, strategy: .iso8601)
            } else {
                resetsAt = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(usedPercentage, forKey: .usedPercentage)
            try c.encodeIfPresent(resetsAt.map(\.timeIntervalSince1970), forKey: .resetsAt)
        }
    }

    public struct RateLimits: Sendable, Codable, Equatable {
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
        try JSONDecoder.statusline.decode(StatuslinePayload.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, transcriptPath, cwd, model, cost, contextWindow, rateLimits, version
    }

    private enum CostKeys: String, CodingKey {
        case totalCostUSD = "totalCostUsd"
    }
}

public extension JSONDecoder {
    /// Decoder matching the statusline JSON's snake_case keys and ISO 8601 dates.
    static var statusline: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension StatuslinePayload.Cost {
    private enum CodingKeys: String, CodingKey {
        // convertFromSnakeCase maps total_cost_usd → totalCostUsd
        case totalCostUSD = "totalCostUsd"
    }
}
