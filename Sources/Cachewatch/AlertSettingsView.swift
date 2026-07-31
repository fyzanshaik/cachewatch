import SwiftUI
import CollectorEngine

struct AlertSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: AlertConfig
    let onSave: (AlertConfig) -> Void

    init(config: AlertConfig, onSave: @escaping (AlertConfig) -> Void) {
        _config = State(initialValue: config)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alert settings")
                        .font(.headline)
                    Text("Choose which conditions should notify you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Notifications", isOn: $config.notificationsEnabled)
                    .toggleStyle(.switch)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    quotaSection
                    cacheExpirySection
                    longIdleSection
                    cacheMissSection
                    needsInputSection
                    turnFinishedSection
                }
                .padding()
            }

            Divider()

            HStack {
                Text("Saved to Cachewatch state.json")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440, height: 600)
    }

    private var quotaSection: some View {
        ruleSection(
            title: "Quota usage",
            detail: "Warn when a current quota window crosses this percentage.",
            isEnabled: $config.quota.enabled
        ) {
            Stepper(value: $config.quota.thresholdPercentage, in: 5...100, step: 5) {
                thresholdLabel("Threshold", value: "\(Int(config.quota.thresholdPercentage))%")
            }
        }
    }

    private var cacheExpirySection: some View {
        ruleSection(
            title: "Cache expiry",
            detail: "Warn before a large five-minute prompt cache expires.",
            isEnabled: $config.cacheExpiry.enabled
        ) {
            Stepper(value: $config.cacheExpiry.warningSeconds, in: 15...300, step: 15) {
                thresholdLabel("Warning", value: duration(config.cacheExpiry.warningSeconds))
            }
            Stepper(value: $config.cacheExpiry.minContextTokens, in: 10_000...1_000_000, step: 10_000) {
                thresholdLabel("Minimum context", value: tokens(config.cacheExpiry.minContextTokens))
            }
        }
    }

    private var longIdleSection: some View {
        ruleSection(
            title: "Long idle",
            detail: "Warn when a large session stays inactive while retaining memory.",
            isEnabled: $config.longIdle.enabled
        ) {
            Stepper(value: $config.longIdle.idleHours, in: 0.5...24, step: 0.5) {
                thresholdLabel("Idle time", value: hours(config.longIdle.idleHours))
            }
            Stepper(value: $config.longIdle.minContextTokens, in: 10_000...1_000_000, step: 10_000) {
                thresholdLabel("Minimum context", value: tokens(config.longIdle.minContextTokens))
            }
            Stepper(value: $config.longIdle.minMemoryBytes, in: 100_000_000...10_000_000_000, step: 100_000_000) {
                thresholdLabel(
                    "Minimum memory",
                    value: ByteCountFormatStyle(style: .memory).format(Int64(config.longIdle.minMemoryBytes))
                )
            }
        }
    }

    private var cacheMissSection: some View {
        ruleSection(
            title: "Cache miss",
            detail: "Warn when a prompt cache is unexpectedly rewritten within its TTL.",
            isEnabled: $config.cacheMiss.enabled
        ) { EmptyView() }
    }

    private var needsInputSection: some View {
        ruleSection(
            title: "Needs input",
            detail: "Warn when a waiting session has needed attention for this long.",
            isEnabled: $config.needsInput.enabled
        ) {
            Stepper(value: $config.needsInput.afterSeconds, in: 30...600, step: 30) {
                thresholdLabel("Waiting time", value: duration(config.needsInput.afterSeconds))
            }
        }
    }

    private var turnFinishedSection: some View {
        ruleSection(
            title: "Long turn finished",
            detail: "Notify when a sustained busy turn completes.",
            isEnabled: $config.turnFinished.enabled
        ) {
            Stepper(value: $config.turnFinished.minBusySeconds, in: 60...3_600, step: 60) {
                thresholdLabel("Minimum duration", value: duration(config.turnFinished.minBusySeconds))
            }
        }
    }

    private func ruleSection<Content: View>(
        title: String,
        detail: String,
        isEnabled: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) { content() }
                    .disabled(!isEnabled.wrappedValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Toggle(title, isOn: isEnabled)
                .toggleStyle(.switch)
                .fontWeight(.medium)
                .accessibilityLabel(title)
        }
        .disabled(!config.notificationsEnabled)
    }

    private func thresholdLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func duration(_ seconds: Double) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds / 60)) min"
        }
        return "\(Int(seconds)) sec"
    }

    private func hours(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) hr" : String(format: "%.1f hr", value)
    }

    private func tokens(_ value: Int) -> String {
        value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
    }
}
