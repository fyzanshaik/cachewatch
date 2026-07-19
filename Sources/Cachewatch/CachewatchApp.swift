import SwiftUI
import CollectorEngine

@main
struct CachewatchApp: App {
    var body: some Scene {
        MenuBarExtra("Cachewatch", systemImage: "gauge.with.dots.needle.50percent") {
            Text("Cachewatch — collector wiring in progress")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
