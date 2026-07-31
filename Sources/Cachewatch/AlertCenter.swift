import Foundation
import ServiceManagement
import UserNotifications
import CollectorEngine

/// Evaluates alert rules against the latest fleet on a timer, delivers macOS
/// notifications, and persists fired-alert keys so restarts don't re-notify.
@MainActor
final class AlertCenter {
    private let store = StateStore()
    private let history = QuotaHistoryStore()
    private let notificationPresenter = ForegroundNotificationPresenter()
    private var state: AppState
    weak var notch: NotchSurface?

    init() {
        state = store.load()
        history.prune()
        if isBundledApp {
            reconcileLaunchAtLoginState()
            UNUserNotificationCenter.current().delegate = notificationPresenter
            requestNotificationAuthorization()
        }
    }

    /// Calibration learned in previous runs, seeded into the collector at launch.
    var storedCalibration: QuotaCalibrator {
        state.calibration ?? QuotaCalibrator()
    }

    var alertConfig: AlertConfig {
        state.alerts
    }

    func updateAlertConfig(_ config: AlertConfig) {
        guard state.alerts != config else { return }
        state.alerts = config
        store.save(state)
    }

    var notchHUDEnabled: Bool {
        get { state.notchHUDEnabled }
        set {
            state.notchHUDEnabled = newValue
            notch?.hudEnabled = newValue
            store.save(state)
        }
    }

    var launchAtLoginLabel: String {
        launchAtLoginStatus.label
    }

    var launchAtLoginHelp: String {
        launchAtLoginStatus.help
    }

    var canManageLaunchAtLogin: Bool {
        launchAtLoginStatus.canManage
    }

    func toggleLaunchAtLogin() {
        guard canManageLaunchAtLogin else { return }
        let enable = !launchAtLoginStatus.isRegistered
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            reconcileLaunchAtLoginState()
        } catch {
            // Keep persisted state aligned with what macOS actually accepted.
            NSLog("Cachewatch could not update launch at login: %@", error.localizedDescription)
        }
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
            history.append(QuotaSample(
                recordedAt: fleet.rateLimitsAsOf ?? Date(),
                fiveHourUsedPercentage: limits.fiveHour?.usedPercentage,
                fiveHourResetsAt: limits.fiveHour?.resetsAt,
                sevenDayUsedPercentage: limits.sevenDay?.usedPercentage,
                sevenDayResetsAt: limits.sevenDay?.resetsAt,
                cumulativeTurnCostUSD: fleet.cumulativeTurnCostUSD
            ))
        }
        if fleet.calibration != state.calibration {
            state.calibration = fleet.calibration
            changed = true
        }
        let alerts = AlertEngine.evaluate(
            fleet: fleet, config: state.alerts, now: Date(), alreadyFired: state.firedAlertKeys
        )
        for alert in AlertDeliveryBatch.make(from: alerts) {
            deliver(alert)
        }
        if !alerts.isEmpty {
            state.firedAlertKeys.formUnion(alerts.map(\.key))
            changed = true
        }
        if changed {
            store.save(state)
        }
    }

    private func deliver(_ alert: Alert) {
        let customAccepted = notch?.show(alert) ?? false
        switch AlertDeliveryRoute.choose(customSurfaceAccepted: customAccepted, isBundledApp: isBundledApp) {
        case .custom:
            break
        case .native:
            deliverNativeNotification(alert)
        case .legacy:
            deliverOSAScript(alert)
        }
    }

    /// Used when a display change interrupts alerts already accepted by the
    /// custom surface. Never retries that surface recursively.
    func deliverWithoutCustomSurface(_ alert: Alert) {
        if isBundledApp {
            deliverNativeNotification(alert)
        } else {
            deliverOSAScript(alert)
        }
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var launchAtLoginStatus: LaunchAtLoginStatus {
        guard isBundledApp else { return .unavailable }
        return switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .pendingApproval
        default: .disabled
        }
    }

    private func reconcileLaunchAtLoginState() {
        let registered = launchAtLoginStatus.isRegistered
        guard state.launchAtLogin != registered else { return }
        state.launchAtLogin = registered
        store.save(state)
    }

    private func requestNotificationAuthorization() {
        Task {
            do {
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
            } catch {
                NSLog("Cachewatch notification authorization failed: %@", error.localizedDescription)
            }
        }
    }

    private func deliverNativeNotification(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let request = UNNotificationRequest(
            identifier: alert.key,
            content: content,
            trigger: nil
        )
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                NSLog("Cachewatch native notification failed: %@", error.localizedDescription)
                deliverOSAScript(alert)
            }
        }
    }

    /// Bare `swift run` executables have no bundle identity for UserNotifications.
    private func deliverOSAScript(_ alert: Alert) {
        let escape = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escape(alert.body))\" with title \"\(escape(alert.title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}

private final class ForegroundNotificationPresenter: NSObject,
    UNUserNotificationCenterDelegate, @unchecked Sendable
{
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

private extension LaunchAtLoginStatus {
    var label: String {
        switch self {
        case .unavailable, .disabled: "Login: off"
        case .pendingApproval: "Login: pending"
        case .enabled: "Login: on"
        }
    }

    var help: String {
        switch self {
        case .unavailable:
            "Launch at login requires the Cachewatch app bundle"
        case .pendingApproval:
            "Approve Cachewatch in System Settings > General > Login Items"
        case .disabled, .enabled:
            "Launch Cachewatch when you log in"
        }
    }
}
