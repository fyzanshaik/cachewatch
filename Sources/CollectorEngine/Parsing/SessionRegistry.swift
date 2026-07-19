import Foundation

/// One file under `~/.claude/sessions/<pid>.json`, written by the Claude Code CLI.
public struct SessionRegistryEntry: Sendable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case idle, busy, waiting
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let name: String?
    public let version: String?
    public let status: Status
    public let startedAt: Date
    public let updatedAt: Date

    public var id: String { sessionId }

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, name, version, status, startedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .unknown
        startedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .startedAt) / 1000)
        updatedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .updatedAt) / 1000)
    }

    public static func decode(from data: Data) throws -> SessionRegistryEntry {
        try JSONDecoder().decode(SessionRegistryEntry.self, from: data)
    }
}
