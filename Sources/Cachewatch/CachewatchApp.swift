import SwiftUI
import CollectorEngine

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("dump") {
            printDump()
        } else {
            CachewatchApp.main()
        }
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
    }
}

/// Bridges the Collector's snapshot stream onto the main actor for SwiftUI.
@MainActor
@Observable
final class FleetModel {
    private(set) var fleet = FleetSnapshot()
    private let collector: Collector
    let alertCenter = AlertCenter()
    private let notchSurface = NotchSurface()

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
            }
        }
        alertCenter.run { [weak self] in self?.fleet ?? FleetSnapshot() }
        Task { [weak self] in
            guard let self else { return }
            self.notchSurface.attach(model: self)
            self.alertCenter.notch = self.notchSurface
            self.notchSurface.hudEnabled = self.alertCenter.notchHUDEnabled
        }
    }
}
