// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crane",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Crane",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/Crane"
        ),
        .testTarget(
            name: "CraneTests",
            dependencies: ["Crane"],
            path: "Tests/CraneTests"
        )
    ]
)
