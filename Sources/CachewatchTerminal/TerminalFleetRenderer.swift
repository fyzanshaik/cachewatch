import Foundation
import CollectorEngine

public enum TerminalFleetRenderer {
    public static func render(_ fleet: FleetSnapshot, now: Date = Date()) -> String {
        guard !fleet.sessions.isEmpty else {
            return "No live Claude Code or Codex sessions."
        }

        var lines: [String] = []
        if let quota = quotaSummary(fleet.rateLimits, now: now) {
            lines.append("Claude quota: \(quota)")
        }
        if let quota = quotaSummary(fleet.codexRateLimits, now: now) {
            lines.append("Codex quota: \(quota)")
        }
        if !lines.isEmpty {
            lines.append("")
        }

        let header = ["AGENT", "SESSION", "STATUS", "MODEL", "CONTEXT", "CACHE", "MEMORY", "LAST TURN"]
        var rows = [header]
        for session in fleet.sessions {
            rows.append([
                session.provider.rawValue,
                session.name ?? String(session.sessionId.prefix(8)),
                session.status.rawValue,
                model(session.model),
                tokens(session.contextTokens),
                cacheState(session, now: now),
                memory(session.memoryBytes),
                session.lastTurnAt.map { age(since: $0, now: now) + " ago" } ?? "—",
            ])
        }
        let widths = (0..<header.count).map { column in
            rows.map { $0[column].count }.max() ?? 0
        }
        lines.append(contentsOf: rows.map { row in
            zip(row, widths)
                .map { $0.padding(toLength: $1 + 2, withPad: " ", startingAt: 0) }
                .joined()
                .trimmingCharacters(in: .whitespaces)
        })
        return lines.joined(separator: "\n")
    }

    private static func tokens(_ count: Int?) -> String {
        guard let count else { return "—" }
        return count >= 1_000 ? "\(count / 1_000)k" : "\(count)"
    }

    private static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        return "\(bytes / 1_000_000) MB"
    }

    private static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func age(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date)) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h \(minutes % 60)m" : "\(hours / 24)d \(hours % 24)h"
    }

    private static func cacheState(_ session: SessionSnapshot, now: Date) -> String {
        switch session.cacheState(at: now) {
        case .warm(let expiresAt):
            return "warm \(countdown(expiresAt.timeIntervalSince(now)))"
        case .cold:
            return "cold"
        case .unknown:
            return "—"
        }
    }

    private static func model(_ id: String?) -> String {
        guard let id else { return "—" }
        let base = id.split(separator: "[").first.map(String.init) ?? id
        return base.replacingOccurrences(of: "claude-", with: "")
    }

    private static func quotaSummary(
        _ limits: StatuslinePayload.RateLimits?,
        now: Date
    ) -> String? {
        let windows: [(String, StatuslinePayload.RateLimitWindow?)] = [
            ("5h", limits?.fiveHour),
            ("7d", limits?.sevenDay),
        ]
        let rendered = windows.compactMap { label, window -> String? in
            guard let used = window?.usedPercentage else { return nil }
            var value = "\(label) \(Int(used))%"
            if let reset = window?.resetsAt, reset > now {
                value += " (resets in \(age(since: now, now: reset)))"
            }
            return value
        }
        return rendered.isEmpty ? nil : rendered.joined(separator: " | ")
    }
}
