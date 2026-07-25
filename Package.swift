// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
let cachewatchExecutable = Target.executableTarget(
    name: "Cachewatch",
    dependencies: ["CollectorEngine", "CachewatchTerminal"],
    path: "Sources/CachewatchCLI"
)
#else
let cachewatchExecutable = Target.executableTarget(
    name: "Cachewatch",
    dependencies: ["CollectorEngine"],
    path: "Sources/Cachewatch"
)
#endif

let package = Package(
    name: "Cachewatch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CollectorEngine", targets: ["CollectorEngine"]),
    ],
    targets: [
        .target(name: "CollectorEngine"),
        .target(
            name: "CachewatchTerminal",
            dependencies: ["CollectorEngine"]
        ),
        cachewatchExecutable,
        .testTarget(
            name: "CollectorEngineTests",
            dependencies: ["CollectorEngine", "CachewatchTerminal"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
