import AppKit
import SwiftUI
import CollectorEngine

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--version") {
            print(packagedVersion ?? "development")
        } else if CommandLine.arguments.contains("dump") {
            printDump()
        } else if CommandLine.arguments.contains("setup") {
            runSetup()
        } else {
            CachewatchApp.main()
        }
    }

    private static var packagedVersion: String? {
        if let version = ProcessInfo.processInfo.environment["CACHEWATCH_VERSION"] {
            return version
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = enclosingAppInfoPlist(for: executable)
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    private static func enclosingAppInfoPlist(for executable: URL) -> URL {
        executable
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .appending(path: "Info.plist")
    }
}

struct CachewatchApp: App {
    @State private var model = FleetModel()

    var body: some Scene {
        MenuBarExtra {
            FleetView(model: model)
        } label: {
            let waiting = model.fleet.sessions.count { $0.status == .waiting }
            if waiting > 0 {
                Image(systemName: "\(waiting).circle.fill")
            } else if let icon = MascotIcon.menuBar {
                Image(nsImage: icon)
            } else {
                // Starburst-plus-timer: the Claude-adjacent asterisk with a cache clock.
                Image(systemName: "timer")
                    .symbolVariant(.none)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 7, weight: .bold))
                            .offset(x: 3, y: -2)
                    }
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showAlertSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Bridges the Collector's snapshot stream onto the main actor for SwiftUI.
@MainActor
@Observable
final class FleetModel {
    private(set) var fleet = FleetSnapshot()
    /// True until the first snapshot arrives — sources are replaying history.
    private(set) var isLoading = true
    private let collector: Collector
    let alertCenter = AlertCenter()
    private let notchSurface = NotchSurface()
    private let settingsWindowController = AlertSettingsWindowController()

    init() {
        collector = Collector(
            calibration: alertCenter.storedCalibration,
            rateLimits: alertCenter.storedRateLimits?.0,
            rateLimitsAsOf: alertCenter.storedRateLimits?.1
        )
        Task {
            await collector.start()
            for await snapshot in await collector.snapshots {
                fleet = snapshot
                isLoading = false
            }
        }
        alertCenter.run { [weak self] in self?.fleet ?? FleetSnapshot() }
        Task { [weak self] in
            guard let self else { return }
            self.notchSurface.attach(model: self)
            self.alertCenter.notch = self.notchSurface
            self.notchSurface.onPresentationUnavailable = { [weak alertCenter = self.alertCenter] alerts in
                for alert in alerts {
                    alertCenter?.deliverWithoutCustomSurface(alert)
                }
            }
            self.notchSurface.hudEnabled = self.alertCenter.notchHUDEnabled
        }
    }

    func showAlertSettings() {
        settingsWindowController.show(config: alertCenter.alertConfig) { [alertCenter] config in
            alertCenter.updateAlertConfig(config)
        }
    }
}

@MainActor
private final class AlertSettingsWindowController {
    private var window: NSWindow?

    func show(config: AlertConfig, onSave: @escaping (AlertConfig) -> Void) {
        let window = window ?? makeWindow()
        window.contentView = NSHostingView(rootView: AlertSettingsView(
            config: config,
            onSave: onSave,
            onDismiss: { [weak self] in self?.window?.close() }
        ))
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Alert settings"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
