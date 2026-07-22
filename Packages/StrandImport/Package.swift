// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandImport",
    platforms: [.iOS(.v17)],
    products: [.library(name: "StrandImport", targets: ["StrandImport"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(name: "StrandImport", dependencies: [
            "WhoopProtocol", "WhoopStore",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "StrandImportTests", dependencies: [
            "StrandImport",
            .product(name: "GRDB", package: "GRDB.swift"),
        ], resources: [
            .copy("Resources"),
        ]),
    ]
)
