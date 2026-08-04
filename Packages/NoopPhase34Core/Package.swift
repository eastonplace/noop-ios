// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoopPhase34Core",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NoopPhase34Core", targets: ["NoopPhase34Core"]),
    ],
    targets: [
        .target(name: "NoopPhase34Core"),
        .testTarget(name: "NoopPhase34CoreTests", dependencies: ["NoopPhase34Core"]),
    ]
)
