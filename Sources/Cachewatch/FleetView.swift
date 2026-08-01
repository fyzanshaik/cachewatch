import SwiftUI
import CollectorEngine

struct FleetView: View {
    let model: FleetModel
    @State private var showingSourceHealth = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header(now: context.date)
                if !model.fleet.warningSources(at: context.date).isEmpty {
                    sourceWarning(now: context.date)
                }
                Divider()
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning Claude Code sessions…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else if model.fleet.sessions.isEmpty {
                    Text("No live Claude Code sessions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(orderedSessions) { session in
                        SessionRow(session: session, now: context.date, fleet: model.fleet)
                    }
                }
                SourceHealthInspector(
                    fleet: model.fleet,
                    now: context.date,
                    isExpanded: $showingSourceHealth
                )
                Divider()
                HStack {
                    memorySummary(now: context.date)
                    Spacer()
                    Button(model.alertCenter.notchHUDEnabled ? "Notch: on" : "Notch: off") {
                        model.alertCenter.notchHUDEnabled.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .help("Hover the notch to open this panel there; alerts appear at the notch either way")
                    Button(model.alertCenter.launchAtLoginLabel) {
                        model.alertCenter.toggleLaunchAtLogin()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .disabled(!model.alertCenter.canManageLaunchAtLogin)
                    .help(model.alertCenter.launchAtLoginHelp)
                    Button("Test alert") { model.alertCenter.deliverTest() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Button("Alert settings", systemImage: "gearshape") {
                        model.showAlertSettings()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Alert settings")
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

    private func memorySummary(now: Date) -> some View {
        let sessions = model.fleet.sessions.compactMap(\.memoryBytes).reduce(0, +)
        let total = SystemMemory.totalBytes
        let systemUsed = SystemMemory.usedBytes()
        let pressure = systemUsed.map { Double($0) / Double(total) } ?? 0
        let qualifier = model.fleet.metricQualifier(for: .process, at: now)
        return Text(
            "\(qualifier == nil ? "" : "~")sessions \(Format.memory(sessions))"
            + (systemUsed.map { " · mac \(Format.memory($0)) / \(Format.memory(total))" } ?? "")
        )
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(pressure > 0.85 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        .monospacedDigit()
        .help(
            qualifier.map { "Session process-tree memory is \($0); machine memory is live." }
                ?? "Session process trees vs total machine memory in use (active + wired + compressed)"
        )
    }

    private func sourceWarning(now: Date) -> some View {
        let warnings = model.fleet.warningSources(at: now)
        return Button {
            showingSourceHealth = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Data incomplete · \(warnings.map { $0.id.displayName }.joined(separator: ", "))")
                    .lineLimit(1)
                Spacer()
                Text("Details")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .help("One or more collectors are stale, degraded, or unavailable")
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
        let quotaQualifier = model.fleet.metricQualifier(for: .statusline, at: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.fleet.sessions.count) session\(model.fleet.sessions.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                if model.fleet.rateLimits == nil {
                    Text(quotaQualifier.map { "quota: \($0)" } ?? "quota: waiting for statusline data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(model.fleet.sourceHealth(for: .statusline)?.message ?? "Waiting for statusline data")
                } else if let quotaQualifier {
                    Text("quota: \(quotaQualifier)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let asOf = model.fleet.rateLimitsAsOf, now.timeIntervalSince(asOf) > 120 {
                    Text("quota as of \(Format.age(since: asOf, now: now)) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if model.fleet.calibration.dollarsPerPercent == nil {
                    Text("learning quota \(Int(model.fleet.calibration.progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Fitting how tokens map to your Plan's 5h window from observed burn; cold-session estimates switch from dollars to % when done")
                }
            }
            if let limits = model.fleet.rateLimits {
                HStack(spacing: 20) {
                    QuotaBadge(label: "5h", window: limits.fiveHour, now: now)
                    QuotaBadge(label: "7d", window: limits.sevenDay, now: now)
                    Spacer()
                }
            }
            QuotaBurnRateSection(
                samples: model.alertCenter.quotaSamples,
                now: now,
                sourceQualifier: quotaQualifier
            )
        }
    }
}

private struct QuotaBurnRateSection: View {
    let samples: [QuotaSample]
    let now: Date
    let sourceQualifier: String?

    private var fiveHour: QuotaBurnRate {
        QuotaBurnRate.derive(from: samples, window: .fiveHour)
    }

    private var sevenDay: QuotaBurnRate {
        QuotaBurnRate.derive(from: samples, window: .sevenDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                burnRow(label: "5h", trend: fiveHour)
                burnRow(label: "7d", trend: sevenDay)
            }
            if let projected = sevenDay.actionableProjectedExhaustion(at: now) {
                Text(
                    sourceQualifier == nil
                        ? "On this pace, weekly cap exhausts \(projected.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                        : "Estimate from last samples: weekly cap exhausts \(projected.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                )
                    .foregroundStyle(.orange)
            } else if !sevenDay.isCurrent(at: now), !sevenDay.points.isEmpty {
                Text("Waiting for the current weekly window")
                    .foregroundStyle(.tertiary)
            } else if sevenDay.projectedExhaustionAt != nil {
                Text("Waiting for a newer weekly quota sample")
                    .foregroundStyle(.tertiary)
            } else if sevenDay.percentagePointsPerHour != nil {
                Text("Weekly pace stays within this window")
                    .foregroundStyle(.secondary)
            } else {
                Text("Collecting quota history for burn rate")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
    }

    private func burnRow(label: String, trend: QuotaBurnRate) -> some View {
        let isCurrent = trend.isCurrent(at: now)
        let rate = isCurrent ? trend.percentagePointsPerHour : nil
        let displayedRate = rate.map {
            "\(sourceQualifier == nil ? "" : "~")\(String(format: "%.1f%%/h", $0))"
        } ?? (!isCurrent && !trend.points.isEmpty ? "expired" : "—")
        return HStack(spacing: 5) {
            Text("\(label) rate")
                .foregroundStyle(.secondary)
            QuotaSparkline(points: trend.points)
                .frame(width: 76, height: 18)
                .accessibilityHidden(true)
            Text(displayedRate)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 50, alignment: .trailing)
        }
        .help("\(trend.points.count) accepted quota samples from the current \(label) window")
    }
}

private struct QuotaSparkline: View {
    let points: [QuotaBurnPoint]

    var body: some View {
        Canvas { context, size in
            guard let first = points.first, let last = points.last else { return }
            let duration = max(1, last.recordedAt.timeIntervalSince(first.recordedAt))
            func position(for point: QuotaBurnPoint) -> CGPoint {
                CGPoint(
                    x: size.width * point.recordedAt.timeIntervalSince(first.recordedAt) / duration,
                    y: size.height * (1 - point.usedPercentage / 100)
                )
            }
            if points.count == 1 {
                let point = position(for: first)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)),
                    with: .color(.secondary)
                )
            } else {
                var path = Path()
                path.move(to: position(for: first))
                for point in points.dropFirst() {
                    path.addLine(to: position(for: point))
                }
                context.stroke(path, with: .color(.secondary), lineWidth: 1.5)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct SourceHealthInspector: View {
    let fleet: FleetSnapshot
    let now: Date
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fleet.sourceHealth) { health in
                    let condition = health.currentCondition(at: now)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: condition))
                                .frame(width: 7, height: 7)
                            Text(health.id.displayName)
                                .fontWeight(.medium)
                            Spacer()
                            Text(condition.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        Text(health.id.affectedMetrics)
                            .foregroundStyle(.tertiary)
                        Text("seen \(health.recordsSeen) · accepted \(health.recordsAccepted) · dropped \(health.recordsDropped)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        if let attempt = health.lastAttemptAt {
                            Text(
                                "attempt \(Format.age(since: attempt, now: now)) ago"
                                + (health.lastSuccessAt.map { " · success \(Format.age(since: $0, now: now)) ago" } ?? "")
                            )
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        }
                        if let message = health.message {
                            Text(message)
                                .foregroundStyle(condition == .unavailable ? .red : .secondary)
                        }
                    }
                    .font(.caption2)
                }
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        fleet.diagnosticsSummary(at: now),
                        forType: .string
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Copies source states, ages, and counters only; no prompts, paths, or transcript content")
            }
            .padding(.top, 5)
        } label: {
            HStack {
                Text("Data sources")
                Spacer()
                if !fleet.warningSources(at: now).isEmpty {
                    Text("needs attention")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    private func color(for condition: SourceCondition) -> Color {
        switch condition {
        case .healthy: .green
        case .stale, .degraded: .orange
        case .unavailable: .red
        case .notConfigured: .secondary
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
    @State private var cacheInsightsExpanded = false

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
                    .help(metricHelp(for: .transcripts))
            }
            HStack(spacing: 10) {
                Text(Format.model(session.model))
                HStack(spacing: 4) {
                    Text("\(transcriptQualifier == nil ? "" : "~")ctx \(Format.tokens(session.contextTokens))")
                    if let fraction = contextFraction {
                        MiniBar(
                            fraction: fraction,
                            color: fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .secondary.opacity(0.6),
                            width: 30
                        )
                        .help("Context window \(Int(fraction * 100))% full — auto-compact approaches at ~95%")
                    }
                }
                .help(metricHelp(for: .transcripts))
                Text("\(memoryQualifier == nil ? "" : "~")\(Format.memory(session.memoryBytes))")
                    .help(metricHelp(for: .process))
                if let cost = session.costUSD, cost > 0 {
                    Text("\(costQualifier == nil ? "" : "~")\(cost.formatted(.currency(code: "USD")))")
                        .help(metricHelp(for: SessionMetric.cost.source))
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
            if let summary = session.cacheSummary {
                cacheEfficiencyDisclosure(summary)
            }
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

    private var transcriptQualifier: String? {
        fleet.metricQualifier(for: .transcripts, at: now)
    }

    private var memoryQualifier: String? {
        fleet.metricQualifier(for: .process, at: now)
    }

    private var costQualifier: String? {
        fleet.metricQualifier(for: SessionMetric.cost.source, at: now)
    }

    private func metricHelp(for source: SourceID) -> String {
        guard let qualifier = fleet.metricQualifier(for: source, at: now) else {
            return source.affectedMetrics
        }
        return "\(source.affectedMetrics) are \(qualifier). Open Data sources for details."
    }

    private func cacheEfficiencyDisclosure(_ summary: SessionCacheSummary) -> some View {
        DisclosureGroup(isExpanded: $cacheInsightsExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mainEvidence(summary))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if summary.main.evidenceQuality == .sufficient,
                   summary.main.cacheWriteTokens > 0 {
                    Text(
                        "Writes · \(Format.tokens(summary.main.fiveMinuteWriteTokens)) at 5m"
                        + " · \(Format.tokens(summary.main.oneHourWriteTokens)) at 1h"
                        + (summary.main.unclassifiedWriteTokens > 0
                            ? " · \(Format.tokens(summary.main.unclassifiedWriteTokens)) TTL unknown"
                            : "")
                    )
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                }
                if summary.sidechains.assistantTurns > 0 {
                    Text(sidechainEvidence(summary.sidechains))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(interpretation(summary))
                    .foregroundStyle(interpretationColor(summary.interpretation))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(interpretation(summary))
            }
            .font(.caption2)
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Cache efficiency")
                Spacer()
                Text(cacheHeadline(summary))
                    .foregroundStyle(headlineColor(summary.interpretation))
                    .monospacedDigit()
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cache efficiency, \(cacheHeadline(summary))")
        }
        .help("Launch-replayed token counters only. No prompts or transcript content are retained.")
    }

    private func cacheHeadline(_ summary: SessionCacheSummary) -> String {
        switch summary.interpretation {
        case .insufficientEvidence: return "learning"
        case .incompleteData: return "partial data"
        case .warmMissObserved: return "\(summary.fullWarmMisses) warm miss\(summary.fullWarmMisses == 1 ? "" : "es")"
        case .awaitingLargeWriteReuse: return "awaiting reuse"
        case .largeWriteTTLUnknown: return "write TTL unknown"
        case .largeWriteNotReused: return "write not reused"
        case .strongReuse: return ratioText(summary.main.cacheEligibleHitRatio)
        case .limitedReuse: return "\(ratioText(summary.main.cacheEligibleHitRatio)) · limited"
        case .neutral: return ratioText(summary.main.cacheEligibleHitRatio)
        }
    }

    private func mainEvidence(_ summary: SessionCacheSummary) -> String {
        let activity = summary.main
        switch activity.evidenceQuality {
        case .insufficient:
            return "Main chain · \(turnText(activity.assistantTurns)) · need at least 2 complete turns"
        case .incomplete:
            return "Main chain · \(activity.turnsWithCompleteUsage) of \(activity.assistantTurns) turns have complete usage"
        case .sufficient:
            let ratio = ratioText(activity.cacheEligibleHitRatio)
            return "Main chain · \(ratio) reuse · \(Format.tokens(activity.cacheReadTokens)) read · \(Format.tokens(activity.cacheWriteTokens)) written · \(turnText(activity.assistantTurns))"
        }
    }

    private func sidechainEvidence(_ activity: CacheActivitySummary) -> String {
        switch activity.evidenceQuality {
        case .insufficient:
            return "Subagents · \(turnText(activity.assistantTurns)) · not enough evidence"
        case .incomplete:
            return "Subagents · \(activity.turnsWithCompleteUsage) of \(activity.assistantTurns) turns have complete usage"
        case .sufficient:
            return "Subagents · \(ratioText(activity.cacheEligibleHitRatio)) reuse · \(Format.tokens(activity.cacheReadTokens)) read · \(Format.tokens(activity.cacheWriteTokens)) written · \(turnText(activity.assistantTurns))"
        }
    }

    private func interpretation(_ summary: SessionCacheSummary) -> String {
        switch summary.interpretation {
        case .insufficientEvidence:
            return "No action yet. Need 2 complete main-chain turns."
        case .incompleteData:
            return "No ratio: \(summary.main.incompleteUsageTurns) turn\(summary.main.incompleteUsageTurns == 1 ? " has" : "s have") incomplete usage."
        case .warmMissObserved:
            return "\(summary.fullWarmMisses) warm full rewrite\(summary.fullWarmMisses == 1 ? "" : "s"). Check model, system prompt, tools, and resume changes."
        case .awaitingLargeWriteReuse:
            return "Latest \(Format.tokens(summary.lastLargeWriteTokens)) write has no later complete turn. Wait before judging."
        case .largeWriteTTLUnknown:
            return "Latest \(Format.tokens(summary.lastLargeWriteTokens)) write has no TTL bucket. Reuse cannot be attributed safely."
        case .largeWriteNotReused:
            if summary.lastLargeWriteExpired,
               summary.turnsAfterLastLargeWrite == 0 {
                return "Latest \(Format.tokens(summary.lastLargeWriteTokens)) write expired before substantial reuse appeared. Future turns cannot prove reuse for that write."
            }
            return "Latest \(Format.tokens(summary.lastLargeWriteTokens)) write had \(turnText(summary.turnsAfterLastLargeWrite)) and no substantial read. Check model, prompt, tools, or session identity."
        case .strongReuse:
            let timing: String
            if case .warm(let expiresAt) = session.cacheState(at: now) {
                timing = " Return within \(Format.countdown(expiresAt.timeIntervalSince(now)))."
            } else {
                timing = ""
            }
            return "\(ratioText(summary.main.cacheEligibleHitRatio)) reuse over \(turnText(summary.main.assistantTurns)). Stay here.\(timing)"
        case .limitedReuse:
            return "Only \(ratioText(summary.main.cacheEligibleHitRatio)) reuse across \(turnText(summary.main.assistantTurns)). If work continues, keep model, prompt, and tools stable."
        case .neutral:
            return "Mixed reuse across \(turnText(summary.main.assistantTurns)). No clear action yet."
        }
    }

    private func ratioText(_ ratio: Double?) -> String {
        guard let ratio else { return "no cache activity" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private func turnText(_ count: Int) -> String {
        "\(count) turn\(count == 1 ? "" : "s")"
    }

    private func headlineColor(_ interpretation: CacheInterpretation) -> Color {
        switch interpretation {
        case .strongReuse: .green
        case .warmMissObserved, .largeWriteNotReused, .limitedReuse: .orange
        case .insufficientEvidence, .incompleteData, .awaitingLargeWriteReuse,
             .largeWriteTTLUnknown, .neutral: .secondary
        }
    }

    private func interpretationColor(_ interpretation: CacheInterpretation) -> Color {
        switch interpretation {
        case .warmMissObserved, .largeWriteNotReused, .limitedReuse: .orange
        case .strongReuse: .green
        case .insufficientEvidence, .incompleteData, .awaitingLargeWriteReuse,
             .largeWriteTTLUnknown, .neutral: .secondary
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
                if let estimate = Pricing.resumeEstimate(for: session, at: now) {
                    let resume = estimate.costUSD
                    let basis = Format.pricingBasis(estimate, model: session.model ?? estimate.price.match)
                    // On a Plan with a fitted calibration, speak in quota; else dollars.
                    if fleet.rateLimits != nil,
                       let pct = fleet.calibration.percentOfWindow(forCost: resume) {
                        Text("~\(pct, format: .number.precision(.fractionLength(pct < 1 ? 1 : 0)))% 5h")
                            .foregroundStyle(.orange.opacity(0.9))
                            .help("Estimated cost to resume as a share of your 5-hour window, from observed quota burn on this account.\n\(basis)")
                    } else {
                        Text("~\(resume, format: .currency(code: "USD"))")
                            .foregroundStyle(.orange.opacity(0.9))
                            .help("Estimated full-context rewrite cost for the next prompt; API list-price equivalent, quota-weight proxy on a subscription.\n\(basis)")
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
