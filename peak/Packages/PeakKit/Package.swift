// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeakKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PeakKit", targets: ["PeakKit"]),
    ],
    targets: [
        .target(name: "PeakKit"),
        .testTarget(name: "PeakKitTests", dependencies: ["PeakKit"]),
    ]
)
