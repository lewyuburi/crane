// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crane",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // UI-agnostic core: runtime driver, compose engine, models. Shared by the app and the CLI.
        .target(
            name: "CraneKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/CraneKit"
        ),
        // The SwiftUI macOS app. Named CraneApp so its build product doesn't collide with the
        // `crane` CLI on case-insensitive filesystems; bundle.sh installs it into Crane.app as "Crane".
        .executableTarget(
            name: "CraneApp",
            dependencies: [
                "CraneKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/CraneApp"
        ),
        // The `crane` command-line tool.
        .executableTarget(
            name: "crane",
            dependencies: [
                "CraneKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CraneCLI"
        ),
        .testTarget(
            name: "CraneTests",
            dependencies: ["CraneKit", "CraneApp"],
            path: "Tests/CraneTests"
        )
    ]
)
