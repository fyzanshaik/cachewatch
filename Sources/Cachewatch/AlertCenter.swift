import Foundation
import CollectorEngine

/// Evaluates alert rules against the latest fleet on a timer, delivers macOS
/// notifications, and persists fired-alert keys so restarts don't re-notify.
@MainActor
final class AlertCenter {
    private let store = StateStore()
    private var state: AppState
    weak var notch: NotchSurface?

    init() {
        state = store.load()
    }

    /// Calibration learned in previous runs, seeded into the collector at launch.
    var storedCalibration: QuotaCalibrator {
        state.calibration ?? QuotaCalibrator()
    }

    /// Last-seen quota, so the display survives restarts (shown with its age).
    var storedRateLimits: (StatuslinePayload.RateLimits, Date)? {
        guard let limits = state.lastRateLimits, let asOf = state.lastRateLimitsAsOf else { return nil }
        return (limits, asOf)
    }

    func deliverTest() {
        deliver(Alert(
            key: "test",
            title: "Cachewatch test notification",
            body: "This is how alerts arrive. Quota, cache expiry, idle sessions, and cache misses all use this."
        ))
    }

    func run(fleet: @escaping @MainActor () -> FleetSnapshot) {
        Task {
            while !Task.isCancelled {
                evaluate(fleet())
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func evaluate(_ fleet: FleetSnapshot) {
        var changed = false
        if let limits = fleet.rateLimits, limits != state.lastRateLimits {
            state.lastRateLimits = limits
            state.lastRateLimitsAsOf = fleet.rateLimitsAsOf
            changed = true
        }
        if fleet.calibration != state.calibration {
            state.calibration = fleet.calibration
            changed = true
        }
        let alerts = AlertEngine.evaluate(
            fleet: fleet, config: state.alerts, now: Date(), alreadyFired: state.firedAlertKeys
        )
        for alert in alerts {
            deliver(alert)
            state.firedAlertKeys.insert(alert.key)
            changed = true
        }
        if changed {
            store.save(state)
        }
    }

    private func deliver(_ alert: Alert) {
        if let notch, notch.canShow {
            notch.show(alert)
        } else {
            deliverOSAScript(alert)
        }
    }

    /// Fallback for clamshell/external-only displays. osascript keeps us working
    /// from a bare `swift run` executable; UserNotifications requires an app
    /// bundle and replaces this once packaged.
    private func deliverOSAScript(_ alert: Alert) {
        let escape = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escape(alert.body))\" with title \"\(escape(alert.title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
