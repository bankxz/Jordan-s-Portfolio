// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RBXPulseServer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "rbxpulse-server", targets: ["RBXPulseServer"]),
    ],
    dependencies: [
        .package(path: "../Packages/RBXPulseKit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "RBXPulseServerCore",
            dependencies: [
                .product(name: "RBXPulseKit", package: "RBXPulseKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .executableTarget(
            name: "RBXPulseServer",
            dependencies: ["RBXPulseServerCore"]
        ),
        .testTarget(
            name: "RBXPulseServerTests",
            dependencies: [
                "RBXPulseServerCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
