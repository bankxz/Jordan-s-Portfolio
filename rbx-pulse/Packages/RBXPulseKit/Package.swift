// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RBXPulseKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RBXPulseKit", targets: ["RBXPulseKit"]),
    ],
    targets: [
        .target(name: "RBXPulseKit"),
        .testTarget(name: "RBXPulseKitTests", dependencies: ["RBXPulseKit"]),
    ]
)
