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
            } else {
                Image(systemName: "gauge.with.dots.needle.50percent")
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
    private let collector = Collector()
    private let alertCenter = AlertCenter()

    init() {
        Task {
            await collector.start()
            for await snapshot in await collector.snapshots {
                fleet = snapshot
            }
        }
        alertCenter.run { [weak self] in self?.fleet ?? FleetSnapshot() }
    }
}
