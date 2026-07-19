import Foundation
import CollectorEngine

enum Format {
    static func tokens(_ count: Int?) -> String {
        guard let count else { return "—" }
        return count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatStyle(style: .memory).format(Int64(bytes))
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date)) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h \(minutes % 60)m" : "\(hours / 24)d \(hours % 24)h"
    }

    static func cacheState(_ session: SessionSnapshot, now: Date = Date()) -> String {
        switch session.cacheState(at: now) {
        case .warm(let expiresAt): "warm \(countdown(expiresAt.timeIntervalSince(now)))"
        case .cold: "cold"
        case .unknown: "—"
        }
    }

    static func model(_ id: String?) -> String {
        guard let id else { return "—" }
        return id.replacingOccurrences(of: "claude-", with: "")
    }
}

func printDump() {
    let fleet = Collector.dump()
    if fleet.sessions.isEmpty {
        print("No live Claude Code sessions.")
        return
    }
    let header = ["SESSION", "STATUS", "MODEL", "CONTEXT", "CACHE", "MEMORY", "LAST TURN"]
    var rows = [header]
    for s in fleet.sessions {
        rows.append([
            s.name ?? String(s.sessionId.prefix(8)),
            s.status.rawValue,
            Format.model(s.model),
            Format.tokens(s.contextTokens),
            Format.cacheState(s),
            Format.memory(s.memoryBytes),
            s.lastTurnAt.map { Format.age(since: $0) + " ago" } ?? "—",
        ])
    }
    let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max()! }
    for row in rows {
        print(zip(row, widths).map { $0.padding(toLength: $1 + 2, withPad: " ", startingAt: 0) }.joined())
    }
}
