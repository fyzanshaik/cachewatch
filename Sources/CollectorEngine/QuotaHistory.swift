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

public enum QuotaWindow: Sendable, Equatable {
    case fiveHour
    case sevenDay
}

public struct QuotaBurnPoint: Sendable, Equatable {
    public let recordedAt: Date
    public let usedPercentage: Double
}

private struct QuotaObservation {
    let recordedAt: Date
    let usedPercentage: Double
    let resetsAt: Date?
}

public struct QuotaBurnRate: Sendable, Equatable {
    public let points: [QuotaBurnPoint]
    public let percentagePointsPerHour: Double?
    public let projectedExhaustionAt: Date?
    public let resetsAt: Date?

    public func isCurrent(at date: Date) -> Bool {
        resetsAt.map { date <= $0 } ?? true
    }

    public func actionableProjectedExhaustion(at date: Date) -> Date? {
        guard isCurrent(at: date), let projectedExhaustionAt, date <= projectedExhaustionAt else {
            return nil
        }
        return projectedExhaustionAt
    }

    public static func derive(
        from samples: [QuotaSample],
        window: QuotaWindow
    ) -> QuotaBurnRate {
        func values(for sample: QuotaSample) -> (used: Double?, reset: Date?) {
            switch window {
            case .fiveHour:
                (sample.fiveHourUsedPercentage, sample.fiveHourResetsAt)
            case .sevenDay:
                (sample.sevenDayUsedPercentage, sample.sevenDayResetsAt)
            }
        }

        let accepted = samples.compactMap { sample -> QuotaObservation? in
            let value = values(for: sample)
            let used = value.used
            guard let used,
                  used.isFinite,
                  (0...100).contains(used)
            else { return nil }
            return QuotaObservation(
                recordedAt: sample.recordedAt,
                usedPercentage: used,
                resetsAt: value.reset
            )
        }
        let observations = Dictionary(grouping: accepted, by: \.recordedAt)
            .compactMap { _, group -> QuotaObservation? in
                guard let first = group.first,
                      group.allSatisfy({
                          $0.usedPercentage == first.usedPercentage
                              && $0.resetsAt == first.resetsAt
                      })
                else { return nil }
                return first
            }
            .sorted { $0.recordedAt < $1.recordedAt }
        let latestReset = observations.reversed().compactMap(\.resetsAt).first
        let points = observations.compactMap { observation -> QuotaBurnPoint? in
            guard observation.resetsAt == latestReset else { return nil }
            return QuotaBurnPoint(
                recordedAt: observation.recordedAt,
                usedPercentage: observation.usedPercentage
            )
        }
        guard latestReset != nil else {
            return QuotaBurnRate(
                points: points,
                percentagePointsPerHour: nil,
                projectedExhaustionAt: nil,
                resetsAt: nil
            )
        }
        var ratePoints = points
        if points.count >= 2 {
            for index in 1..<points.count where points[index].usedPercentage < points[index - 1].usedPercentage {
                ratePoints = Array(points[index...])
            }
        }
        guard let first = ratePoints.first, let last = ratePoints.last, ratePoints.count >= 2 else {
            return QuotaBurnRate(
                points: points,
                percentagePointsPerHour: nil,
                projectedExhaustionAt: nil,
                resetsAt: latestReset
            )
        }
        let elapsedHours = last.recordedAt.timeIntervalSince(first.recordedAt) / 3_600
        guard elapsedHours > 0 else {
            return QuotaBurnRate(
                points: points,
                percentagePointsPerHour: nil,
                projectedExhaustionAt: nil,
                resetsAt: latestReset
            )
        }
        let rate = (last.usedPercentage - first.usedPercentage) / elapsedHours
        let projected = rate > 0 && last.usedPercentage < 100
            ? last.recordedAt.addingTimeInterval((100 - last.usedPercentage) / rate * 3_600)
            : nil
        return QuotaBurnRate(
            points: points,
            percentagePointsPerHour: rate,
            projectedExhaustionAt: projected.flatMap { date in
                latestReset.map { date <= $0 ? date : nil } ?? date
            },
            resetsAt: latestReset
        )
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
