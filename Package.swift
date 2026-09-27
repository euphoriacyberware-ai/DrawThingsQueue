// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DrawThingsQueue",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "DrawThingsQueue",
            targets: ["DrawThingsQueue"]
        ),
    ],
    dependencies: [
        // Use remote URLs for release
        .package(url: "https://github.com/euphoriacyberware-ai/DT-gRPC-Swift-Client", .upToNextMajor(from: "1.7.2")),
    ],
    targets: [
        .target(
            name: "DrawThingsQueue",
            dependencies: [
                .product(name: "DrawThingsClient", package: "DT-gRPC-Swift-Client"),
            ]
        ),
        .testTarget(
            name: "DrawThingsQueueTests",
            dependencies: ["DrawThingsQueue"]
        ),
    ]
)
