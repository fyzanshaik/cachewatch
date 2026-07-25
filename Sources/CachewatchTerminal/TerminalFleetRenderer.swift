import Foundation
import CollectorEngine

public enum TerminalOutputStyle: Sendable, Equatable {
    case plain
    case ansi
}

public enum TerminalFleetRenderer {
    private static let contextBarWidth = 8
    private static let quotaBarWidth = 12

    public static func render(
        _ fleet: FleetSnapshot,
        now: Date = Date(),
        style: TerminalOutputStyle = .plain,
        live: Bool = false
    ) -> String {
        let summary = fleetSummary(fleet)
        var titleParts = [paint("CACHEWATCH", codes: [1, 36], style: style)]
        if live {
            titleParts.append(paint("[LIVE]", codes: [1, 32], style: style))
        }
        titleParts.append(paint(summary, codes: [2], style: style))

        guard !fleet.sessions.isEmpty else {
            var lines = [
                titleParts.joined(separator: "  "),
                paint(String(repeating: "─", count: 72), codes: [2], style: style),
                "",
                paint("No live Claude Code or Codex sessions.", codes: [2], style: style),
            ]
            if live {
                lines += ["", paint("Live refresh  ·  Ctrl-C to stop", codes: [2], style: style)]
            }
            return lines.joined(separator: "\n")
        }

        let header = ["AGENT", "SESSION", "STATUS", "MODEL", "CONTEXT", "CACHE", "MEMORY", "LAST TURN"]
        let rows = fleet.sessions.map { session in
            [
                session.provider.rawValue.uppercased(),
                truncate(session.name ?? String(session.sessionId.prefix(8)), to: 18),
                statusLabel(session.status),
                truncate(model(session.model), to: 18),
                context(session),
                cacheState(session, now: now),
                memory(session.memoryBytes),
                session.lastTurnAt.map { age(since: $0, now: now) + " ago" } ?? "—",
            ]
        }
        let widths = (0..<header.count).map { column in
            ([header[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        let tableWidth = widths.reduce(0, +) + (header.count - 1) * 2
        let rule = String(repeating: "─", count: tableWidth)

        var lines = [
            titleParts.joined(separator: "  "),
            paint(rule, codes: [2], style: style),
        ]

        let quotas = quotaRows(fleet: fleet, now: now, style: style)
        if !quotas.isEmpty {
            lines.append("")
            lines.append(paint("QUOTA", codes: [1, 2], style: style))
            lines.append(contentsOf: quotas)
        }

        lines.append("")
        lines.append(paint(renderRow(header, widths: widths), codes: [1, 2], style: style))
        lines.append(paint(rule, codes: [2], style: style))
        for (session, row) in zip(fleet.sessions, rows) {
            lines.append(renderSessionRow(session, values: row, widths: widths, now: now, style: style))
        }

        if live {
            lines += ["", paint("Live refresh  ·  Ctrl-C to stop", codes: [2], style: style)]
        }
        return lines.joined(separator: "\n")
    }

    private static func fleetSummary(_ fleet: FleetSnapshot) -> String {
        let count = fleet.sessions.count
        let busy = fleet.sessions.count { $0.status == .busy }
        let idle = fleet.sessions.count { $0.status == .idle }
        let waiting = fleet.sessions.count { $0.status == .waiting }
        var parts = ["\(count) session\(count == 1 ? "" : "s")"]
        if busy > 0 { parts.append("\(busy) busy") }
        if idle > 0 { parts.append("\(idle) idle") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: "  ·  ")
    }

    private static func quotaRows(
        fleet: FleetSnapshot,
        now: Date,
        style: TerminalOutputStyle
    ) -> [String] {
        quotaRows(provider: "Claude", limits: fleet.rateLimits, now: now, style: style)
            + quotaRows(provider: "Codex", limits: fleet.codexRateLimits, now: now, style: style)
    }

    private static func quotaRows(
        provider: String,
        limits: StatuslinePayload.RateLimits?,
        now: Date,
        style: TerminalOutputStyle
    ) -> [String] {
        let windows: [(String, StatuslinePayload.RateLimitWindow?)] = [
            ("5h", limits?.fiveHour),
            ("7d", limits?.sevenDay),
        ]
        return windows.compactMap { label, window in
            guard let used = window?.usedPercentage else { return nil }
            let prefix = provider.padding(toLength: 7, withPad: " ", startingAt: 0)
            var value = "\(prefix) \(label)  \(progressBar(used, width: quotaBarWidth)) \(Int(used))%"
            if let reset = window?.resetsAt, reset > now {
                value += "  resets in \(age(since: now, now: reset))"
            }
            return paint(value, codes: percentageColor(used), style: style)
        }
    }

    private static func renderSessionRow(
        _ session: SessionSnapshot,
        values: [String],
        widths: [Int],
        now: Date,
        style: TerminalOutputStyle
    ) -> String {
        values.enumerated().map { index, value in
            let padded = paddedCell(value, column: index, widths: widths)
            let codes: [Int]
            switch index {
            case 0:
                codes = session.provider == .codex ? [1, 35] : [1, 36]
            case 2:
                codes = statusColor(session.status)
            case 4:
                codes = session.contextUsedPercentage.map(percentageColor) ?? [0]
            case 5:
                switch session.cacheState(at: now) {
                case .warm: codes = [32]
                case .cold: codes = [31]
                case .unknown: codes = [2]
                }
            case 6:
                codes = (session.memoryBytes ?? 0) >= 1_000_000_000 ? [33] : [0]
            case 7:
                codes = [2]
            default:
                codes = [0]
            }
            return paint(padded, codes: codes, style: style)
        }.joined()
    }

    private static func renderRow(_ values: [String], widths: [Int]) -> String {
        values.enumerated().map { index, value in
            paddedCell(value, column: index, widths: widths)
        }.joined()
    }

    private static func paddedCell(_ value: String, column: Int, widths: [Int]) -> String {
        guard column < widths.count - 1 else { return value }
        return value.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0)
    }

    private static func context(_ session: SessionSnapshot) -> String {
        guard let percentage = session.contextUsedPercentage else {
            return tokens(session.contextTokens)
        }
        return "\(progressBar(percentage, width: contextBarWidth)) \(Int(percentage))% · \(tokens(session.contextTokens))"
    }

    private static func progressBar(_ percentage: Double, width: Int) -> String {
        let clamped = min(100, max(0, percentage))
        let filled = Int((clamped / 100 * Double(width)).rounded())
        return "[" + String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled) + "]"
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

    private static func statusLabel(_ status: SessionRegistryEntry.Status) -> String {
        switch status {
        case .idle: return "IDLE"
        case .busy: return "BUSY"
        case .waiting: return "WAITING"
        case .unknown: return "UNKNOWN"
        }
    }

    private static func model(_ id: String?) -> String {
        guard let id else { return "—" }
        let base = id.split(separator: "[").first.map(String.init) ?? id
        return base.replacingOccurrences(of: "claude-", with: "")
    }

    private static func truncate(_ value: String, to limit: Int) -> String {
        guard value.count > limit, limit > 1 else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func percentageColor(_ percentage: Double) -> [Int] {
        if percentage >= 90 { return [1, 31] }
        if percentage >= 70 { return [33] }
        return [36]
    }

    private static func statusColor(_ status: SessionRegistryEntry.Status) -> [Int] {
        switch status {
        case .idle: return [32]
        case .busy: return [1, 36]
        case .waiting: return [1, 33]
        case .unknown: return [2]
        }
    }

    private static func paint(
        _ value: String,
        codes: [Int],
        style: TerminalOutputStyle
    ) -> String {
        guard style == .ansi, codes != [0] else { return value }
        return "\u{001B}[\(codes.map(String.init).joined(separator: ";"))m\(value)\u{001B}[0m"
    }
}
