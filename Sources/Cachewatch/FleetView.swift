import SwiftUI
import CollectorEngine

struct FleetView: View {
    let model: FleetModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header(now: context.date)
                Divider()
                if model.fleet.sessions.isEmpty {
                    Text("No live Claude Code sessions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(orderedSessions) { session in
                        SessionRow(session: session, now: context.date, fleet: model.fleet)
                    }
                }
                Divider()
                HStack {
                    memorySummary
                    Spacer()
                    Button("Test alert") { model.alertCenter.deliverTest() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(14)
            .frame(width: 470)
        }
    }

    private var memorySummary: some View {
        let sessions = model.fleet.sessions.compactMap(\.memoryBytes).reduce(0, +)
        let total = SystemMemory.totalBytes
        let systemUsed = SystemMemory.usedBytes()
        let pressure = systemUsed.map { Double($0) / Double(total) } ?? 0
        return Text(
            "sessions \(Format.memory(sessions))"
            + (systemUsed.map { " · mac \(Format.memory($0)) / \(Format.memory(total))" } ?? "")
        )
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(pressure > 0.85 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        .monospacedDigit()
        .help("Session process trees vs total machine memory in use (active + wired + compressed)")
    }

    /// Sessions needing input first, then by recency of activity.
    private var orderedSessions: [SessionSnapshot] {
        model.fleet.sessions.sorted { a, b in
            if (a.status == .waiting) != (b.status == .waiting) {
                return a.status == .waiting
            }
            return (a.lastTurnAt ?? a.updatedAt) > (b.lastTurnAt ?? b.updatedAt)
        }
    }

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack {
            Text("\(model.fleet.sessions.count) session\(model.fleet.sessions.count == 1 ? "" : "s")")
                .font(.headline)
            Spacer()
            if let limits = model.fleet.rateLimits {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 8) {
                        QuotaBadge(label: "5h", window: limits.fiveHour, now: now)
                        QuotaBadge(label: "7d", window: limits.sevenDay, now: now)
                    }
                    if let asOf = model.fleet.rateLimitsAsOf, now.timeIntervalSince(asOf) > 120 {
                        Text("as of \(Format.age(since: asOf, now: now)) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if model.fleet.calibration.dollarsPerPercent == nil {
                        Text("learning quota \(Int(model.fleet.calibration.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Fitting how tokens map to your Plan's 5h window from observed burn; cold-session estimates switch from dollars to % when done")
                    }
                }
            } else {
                Text("quota: waiting for statusline data")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Thin capacity bar used for quota, context, and cache countdowns.
private struct MiniBar: View {
    let fraction: Double
    let color: Color
    var width: CGFloat = 44

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: max(3, width * min(1, max(0, fraction))))
            }
    }
}

private func quotaColor(_ used: Double) -> Color {
    used >= 80 ? .red : used >= 60 ? .orange : .green
}

private struct QuotaBadge: View {
    let label: String
    let window: StatuslinePayload.RateLimitWindow?
    let now: Date

    var body: some View {
        if let window, let used = window.usedPercentage {
            HStack(spacing: 5) {
                Text(label).foregroundStyle(.secondary)
                if window.isExpired(at: now) {
                    Text("reset").foregroundStyle(.green)
                } else {
                    MiniBar(fraction: used / 100, color: quotaColor(used))
                    Text("\(Int(used))%")
                        .foregroundStyle(used >= 80 ? .red : used >= 60 ? .orange : .primary)
                        .monospacedDigit()
                    if let resetsAt = window.resetsAt {
                        Text("· \(Format.age(since: now, now: resetsAt))")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

private struct SessionRow: View {
    let session: SessionSnapshot
    let now: Date
    let fleet: FleetSnapshot
    @State private var confirmingClose = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(session.name ?? String(session.sessionId.prefix(8)))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(2)
                    .help(session.cwd)
                if let host = session.hostAppName {
                    Button {
                        if let pid = session.hostAppPid {
                            NSRunningApplication(processIdentifier: pid)?
                                .activate(options: [.activateAllWindows])
                        }
                    } label: {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quinary))
                    }
                    .buttonStyle(.plain)
                    .help("Running in \(host) — click to bring it forward")
                }
                if let branch = session.gitBranch {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if session.status == .waiting {
                    Text("needs input")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                }
                cacheBadge
            }
            HStack(spacing: 10) {
                Text(Format.model(session.model))
                HStack(spacing: 4) {
                    Text("ctx \(Format.tokens(session.contextTokens))")
                    if let fraction = contextFraction {
                        MiniBar(
                            fraction: fraction,
                            color: fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .secondary.opacity(0.6),
                            width: 30
                        )
                        .help("Context window \(Int(fraction * 100))% full — auto-compact approaches at ~95%")
                    }
                }
                Text(Format.memory(session.memoryBytes))
                if let cost = session.costUSD, cost > 0 {
                    Text(cost, format: .currency(code: "USD"))
                }
                Spacer()
                // Both trailing views live in one ZStack so hover toggles opacity,
                // never row width — otherwise the list wobbles under the pointer.
                ZStack(alignment: .trailing) {
                    if let last = session.lastTurnAt {
                        Text("\(Format.age(since: last, now: now)) ago")
                            .opacity(hovering ? 0 : 1)
                    }
                    Button("Close session") {
                        confirmingClose = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
                    .help("Quits this Claude Code process (asks first)")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .confirmationDialog(
            "Close \(session.name ?? session.sessionId)?",
            isPresented: $confirmingClose
        ) {
            Button("Close session", role: .destructive) {
                kill(session.pid, SIGTERM)
            }
        } message: {
            Text("Sends SIGTERM to the Claude Code process. Unsaved prompt drafts in that terminal are lost.")
        }
    }

    /// Statusline-reported fill when available. Fallback infers the window class:
    /// holding more than 200k tokens proves a 1M window, so dividing by 200k
    /// would peg the bar red on perfectly healthy sessions.
    private var contextFraction: Double? {
        if let pct = session.contextUsedPercentage { return pct / 100 }
        return session.contextTokens.map { tokens in
            let window = tokens > 180_000 ? 1_000_000.0 : 200_000.0
            return min(1, Double(tokens) / window)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .busy: .green
        case .waiting: .orange
        case .idle: .gray
        case .unknown: .gray.opacity(0.4)
        }
    }

    @ViewBuilder
    private var cacheBadge: some View {
        switch session.cacheState(at: now) {
        case .warm(let expiresAt):
            let remaining = expiresAt.timeIntervalSince(now)
            VStack(alignment: .trailing, spacing: 2) {
                Text("warm \(Format.countdown(remaining))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(remaining < 120 ? .orange : .green)
                if let ttl = session.cacheTTL {
                    MiniBar(
                        fraction: remaining / ttl.duration,
                        color: remaining < 120 ? .orange : .green
                    )
                }
            }
        case .cold:
            HStack(spacing: 4) {
                Text("cold")
                    .foregroundStyle(.secondary)
                if let resume = Pricing.costToResume(for: session, at: now) {
                    // On a Plan with a fitted calibration, speak in quota; else dollars.
                    if fleet.rateLimits != nil,
                       let pct = fleet.calibration.percentOfWindow(forCost: resume) {
                        Text("~\(pct, format: .number.precision(.fractionLength(pct < 1 ? 1 : 0)))% 5h")
                            .foregroundStyle(.orange.opacity(0.9))
                            .help("Cost to resume as a share of your 5-hour window, from observed quota burn on this account")
                    } else {
                        Text("~\(resume, format: .currency(code: "USD"))")
                            .foregroundStyle(.orange.opacity(0.9))
                            .help("Cost to resume: the full-context rewrite the next prompt pays (API list price; quota-weight proxy on a subscription)")
                    }
                }
            }
            .font(.caption)
            .monospacedDigit()
        case .unknown:
            EmptyView()
        }
    }
}
