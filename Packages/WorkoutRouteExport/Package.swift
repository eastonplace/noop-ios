// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkoutRouteExport",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "WorkoutRouteExport", targets: ["WorkoutRouteExport"])],
    targets: [
        .target(name: "WorkoutRouteExport"),
        .testTarget(name: "WorkoutRouteExportTests", dependencies: ["WorkoutRouteExport"]),
    ]
)
