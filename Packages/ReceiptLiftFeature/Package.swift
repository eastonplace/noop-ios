// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReceiptLiftFeature", platforms: [.iOS(.v17)], products: [.library(name: "ReceiptLiftFeature", targets: ["ReceiptLiftFeature"])], dependencies: [.package(path: "../StrandDesign"), .package(path: "../ReceiptLiftActivity")], targets: [.target(name: "ReceiptLiftFeature", dependencies: ["StrandDesign", "ReceiptLiftActivity"], resources: [.process("Resources/Assets.xcassets"), .copy("Resources/ExerciseCatalog")])])
