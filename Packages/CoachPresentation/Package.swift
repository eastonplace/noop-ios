// swift-tools-version:5.9
import PackageDescription

// Keep MarkdownUI's result builders in its Swift 5 language mode. The Swift 6
// app consumes the concrete Theme while UI ownership remains on MainActor.
let package = Package(
    name: "CoachPresentation",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CoachPresentation", targets: ["CoachPresentation"])],
    dependencies: [
        .package(path: "../StrandDesign"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [.target(name: "CoachPresentation", dependencies: [
        "StrandDesign", .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    ])]
)
