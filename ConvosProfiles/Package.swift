// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosProfiles",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Core profile types (no XMTP dependency)
        .library(
            name: "ConvosProfilesCore",
            targets: ["ConvosProfilesCore"]
        ),
        // Full package with XMTP integration
        .library(
            name: "ConvosProfiles",
            targets: ["ConvosProfiles"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(
            url: "https://github.com/xmtp/libxmtp.git",
            revision: "ios-4.9.0-dev.6ecd439"
        ),
    ],
    targets: [
        // Core profile types - no XMTP dependency
        .target(
            name: "ConvosProfilesCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/ConvosProfilesCore"
        ),
        // XMTP integration layer
        .target(
            name: "ConvosProfiles",
            dependencies: [
                "ConvosProfilesCore",
                .product(name: "XMTPiOS", package: "libxmtp"),
            ],
            path: "Sources/ConvosProfiles"
        ),
        .testTarget(
            name: "ConvosProfilesCoreTests",
            dependencies: ["ConvosProfilesCore"],
            path: "Tests/ConvosProfilesCoreTests"
        ),
        .testTarget(
            name: "ConvosProfilesTests",
            dependencies: ["ConvosProfiles"],
            path: "Tests/ConvosProfilesTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
