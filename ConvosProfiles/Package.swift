// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosProfiles",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Full package with XMTP integration
        .library(
            name: "ConvosProfiles",
            targets: ["ConvosProfiles"]
        ),
    ],
    dependencies: [
        .package(path: "../ConvosAppData"),
        .package(path: "../ConvosMessagingProtocols"),
        .package(
            url: "https://github.com/xmtp/libxmtp.git",
            revision: "ios-4.9.0-dev.88ddfad"
        ),
    ],
    targets: [
        // XMTP integration layer - depends on ConvosAppData for shared types
        .target(
            name: "ConvosProfiles",
            dependencies: [
                .product(name: "ConvosAppData", package: "ConvosAppData"),
                .product(name: "ConvosMessagingProtocols", package: "ConvosMessagingProtocols"),
                .product(name: "XMTPiOS", package: "libxmtp"),
            ],
            path: "Sources/ConvosProfiles"
        ),
        .testTarget(
            name: "ConvosProfilesTests",
            dependencies: ["ConvosProfiles"],
            path: "Tests/ConvosProfilesTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
