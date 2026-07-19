import Foundation

/// One accepted quota observation — the raw material for burn-rate trends,
/// exhaustion projections, and auditing the calibration fit against reality.
public struct QuotaSample: Sendable, Codable, Equatable {
    public let recordedAt: Date
    public let fiveHourUsedPercentage: Double?
    public let fiveHourResetsAt: Date?
    public let sevenDayUsedPercentage: Double?
    public let sevenDayResetsAt: Date?
    public let cumulativeTurnCostUSD: Double

    public init(
        recordedAt: Date,
        fiveHourUsedPercentage: Double?,
        fiveHourResetsAt: Date?,
        sevenDayUsedPercentage: Double?,
        sevenDayResetsAt: Date?,
        cumulativeTurnCostUSD: Double
    ) {
        self.recordedAt = recordedAt
        self.fiveHourUsedPercentage = fiveHourUsedPercentage
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayUsedPercentage = sevenDayUsedPercentage
        self.sevenDayResetsAt = sevenDayResetsAt
        self.cumulativeTurnCostUSD = cumulativeTurnCostUSD
    }
}

/// Append-only JSONL next to state.json. Unbounded data stays out of the config
/// file; pruning at launch keeps it to a rolling window.
public struct QuotaHistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cachewatch/quota-history.jsonl")
    }

    public func append(_ sample: QuotaSample) {
        guard let data = try? encoder.encode(sample) else { return }
        let line = data + Data("\n".utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line)
    }

    public func load() -> [QuotaSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(QuotaSample.self, from: Data($0.utf8)) }
    }

    /// Rewrites the file keeping only samples newer than the window; also sheds
    /// any unparseable lines.
    public func prune(olderThan window: TimeInterval = 30 * 86_400, now: Date = Date()) {
        let kept = load().filter { now.timeIntervalSince($0.recordedAt) <= window }
        let lines = kept.compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        try? Data((lines + (lines.isEmpty ? "" : "\n")).utf8).write(to: fileURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
