// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConvosLogging",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ConvosLogging",
            targets: ["ConvosLogging"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0")
    ],
    targets: [
        .target(
            name: "ConvosLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        )
    ]
)
