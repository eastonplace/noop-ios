// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandDesign",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [.library(name: "StrandDesign", targets: ["StrandDesign"])],
    dependencies: [],
    targets: [
        .target(name: "StrandDesign", resources: [.process("Resources")]),
        .testTarget(name: "StrandDesignTests", dependencies: ["StrandDesign"]),
    ]
)
