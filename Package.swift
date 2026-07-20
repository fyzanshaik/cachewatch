// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cachewatch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CollectorEngine", targets: ["CollectorEngine"]),
    ],
    targets: [
        .target(name: "CollectorEngine"),
        .executableTarget(
            name: "Cachewatch",
            dependencies: ["CollectorEngine"]
        ),
        .testTarget(
            name: "CollectorEngineTests",
            dependencies: ["CollectorEngine"],
            resources: [.copy("Fixtures")]
        ),
        // Interim runner until issue #2 ports the canonical cases to Swift Testing.
        .executableTarget(
            name: "cachewatch-tests",
            dependencies: ["CollectorEngine"],
            path: "Sources/CachewatchTests"
        ),
    ]
)
