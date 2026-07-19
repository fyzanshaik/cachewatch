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
            Image(systemName: "gauge.with.dots.needle.50percent")
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

    init() {
        Task {
            await collector.start()
            for await snapshot in await collector.snapshots {
                fleet = snapshot
            }
        }
    }
}
