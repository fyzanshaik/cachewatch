import Foundation

/// The app's single persisted file. Everything else is rebuilt from agent-local
/// files on launch. Missing fields decode to defaults, so schema additions never
/// need migrations.
public struct AppState: Sendable, Equatable, Codable {
    public var schemaVersion = 1
    public var alerts = AlertConfig.default
    public var firedAlertKeys: Set<String> = []
    public var lastRateLimits: StatuslinePayload.RateLimits?
    public var lastRateLimitsAsOf: Date?
    public var calibration: QuotaCalibrator?
    public var notchHUDEnabled = false
    public var launchAtLogin = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        alerts = try c.decodeIfPresent(AlertConfig.self, forKey: .alerts) ?? .default
        firedAlertKeys = try c.decodeIfPresent(Set<String>.self, forKey: .firedAlertKeys) ?? []
        lastRateLimits = try c.decodeIfPresent(StatuslinePayload.RateLimits.self, forKey: .lastRateLimits)
        lastRateLimitsAsOf = try c.decodeIfPresent(Date.self, forKey: .lastRateLimitsAsOf)
        calibration = try c.decodeIfPresent(QuotaCalibrator.self, forKey: .calibration)
        notchHUDEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchHUDEnabled) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }
}

public struct StateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cachewatch/state.json")
    }

    public func load() -> AppState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? AppState.decode(from: data)
        else { return AppState() }
        return state
    }

    public func save(_ state: AppState) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? (try? state.encoded())?.write(to: fileURL, options: .atomic)
    }
}
