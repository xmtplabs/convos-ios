// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosAppData",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "ConvosAppData",
            targets: ["ConvosAppData"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "ConvosAppData",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/ConvosAppData"
        ),
        .testTarget(
            name: "ConvosAppDataTests",
            dependencies: ["ConvosAppData"],
            path: "Tests/ConvosAppDataTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
