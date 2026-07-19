// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cachewatch",
    platforms: [.macOS(.v15)],
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
        // Interim runner until Xcode (and with it XCTest/Swift Testing) is installed:
        // `swift run cachewatch-tests` executes the same cases with plain assertions.
        .executableTarget(
            name: "cachewatch-tests",
            dependencies: ["CollectorEngine"],
            path: "Sources/CachewatchTests"
        ),
    ]
)
