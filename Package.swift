// swift-tools-version: 6.2
import PackageDescription

/// Crane 2.0 is layered strictly bottom-up: each target below knows nothing about the ones
/// above it. `DockerAPI`, `AppleContainer` and `EngineControl` are the three ways Crane can
/// touch the outside world; `CraneCore` turns them into state; `CraneUI` renders it.
let package = Package(
    name: "Crane",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DockerAPI", targets: ["DockerAPI"]),
        .library(name: "EngineControl", targets: ["EngineControl"]),
        .library(name: "CraneCore", targets: ["CraneCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    ],
    targets: [
        // Docker Engine API v1.51 over a UNIX socket. No UI, no process spawning: this is the
        // hot path for everything the app displays.
        .target(
            name: "DockerAPI",
            dependencies: [.product(name: "AsyncHTTPClient", package: "async-http-client")]
        ),
        // The parts only Apple's own runtime can do: machines, system/kernel, DNS domains,
        // and the PTY behind `container exec`.
        .target(name: "AppleContainer"),
        // Owns the stack Crane installs and supervises: runtime + socktainer + docker CLIs,
        // their launch agents, the docker context, and the diagnostics that repair them.
        .target(name: "EngineControl", dependencies: ["AppleContainer"]),
        // Domain model and the observable store. The event reducer lives here and is pure.
        .target(name: "CraneCore", dependencies: ["DockerAPI", "AppleContainer", "EngineControl"]),

        // Design system and views.
        .target(name: "CraneUI", dependencies: ["CraneCore"]),
        // Thin executables.
        .executableTarget(name: "CraneApp", dependencies: ["CraneUI"]),
        .executableTarget(
            name: "crane",
            dependencies: ["CraneCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/CraneCLI"
        ),

        .testTarget(name: "DockerAPITests", dependencies: ["DockerAPI"]),
        .testTarget(name: "EngineControlTests", dependencies: ["EngineControl"]),
        .testTarget(name: "CraneCoreTests", dependencies: ["CraneCore"]),
    ]
)
