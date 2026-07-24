// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    // The product ships in the iPhone app. macOS remains only as a SwiftPM host for headless tests.
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "StrandAnalytics", targets: ["StrandAnalytics"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(name: "StrandAnalytics", dependencies: ["WhoopProtocol", "WhoopStore"]),
        .testTarget(
            name: "StrandAnalyticsTests",
            dependencies: ["StrandAnalytics", "WhoopProtocol"]
        ),
    ]
)
