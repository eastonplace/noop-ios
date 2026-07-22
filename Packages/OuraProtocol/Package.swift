// swift-tools-version: 5.9
import PackageDescription

// Clean-room Oura Ring BLE protocol package. The library stays platform-neutral internally; the product
// is consumed by the iPhone application and its tests.
let package = Package(
    name: "OuraProtocol",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "OuraProtocol", targets: ["OuraProtocol"]),
        .executable(name: "oura-decode", targets: ["oura-decode"]),
    ],
    targets: [
        .target(name: "OuraProtocol"),
        .executableTarget(
            name: "oura-decode",
            dependencies: ["OuraProtocol"]
        ),
        .testTarget(
            name: "OuraProtocolTests",
            dependencies: ["OuraProtocol"]
        ),
    ]
)
