// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeakServer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "peak-server", targets: ["PeakServer"]),
    ],
    dependencies: [
        .package(path: "../Packages/PeakKit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "PeakServerCore",
            dependencies: [
                .product(name: "PeakKit", package: "PeakKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .executableTarget(
            name: "PeakServer",
            dependencies: ["PeakServerCore"]
        ),
        .testTarget(
            name: "PeakServerTests",
            dependencies: [
                "PeakServerCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
