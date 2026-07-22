// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandDesign",
    defaultLocalization: "en",
    // The design system ships in the iPhone app. macOS remains only as a SwiftPM test host.
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "StrandDesign", targets: ["StrandDesign"])],
    dependencies: [],
    targets: [
        .target(name: "StrandDesign", resources: [.process("Resources")]),
        .testTarget(name: "StrandDesignTests", dependencies: ["StrandDesign"]),
    ]
)
