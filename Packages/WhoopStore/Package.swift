// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopStore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "WhoopStore", targets: ["WhoopStore"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../OuraProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "WhoopStore",
            dependencies: [
                "WhoopProtocol",
                "OuraProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WhoopStoreTests",
            dependencies: ["WhoopStore", "WhoopProtocol", "OuraProtocol"]
        ),
    ]
)
