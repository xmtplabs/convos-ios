// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosInvites",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Core crypto layer (no XMTP dependency)
        .library(
            name: "ConvosInvitesCore",
            targets: ["ConvosInvitesCore"]
        ),
        // Full package with XMTP integration
        .library(
            name: "ConvosInvites",
            targets: ["ConvosInvites"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/tesseract-one/CSecp256k1.swift.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(
            url: "https://github.com/xmtp/libxmtp.git",
            revision: "ios-4.10.0-dev.d991b8a"
        ),
        .package(path: "../ConvosAppData"),
    ],
    targets: [
        // Core crypto layer - no XMTP dependency
        .target(
            name: "ConvosInvitesCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "CSecp256k1", package: "CSecp256k1.swift"),
            ],
            path: "Sources/ConvosInvitesCore"
        ),
        // XMTP integration layer
        .target(
            name: "ConvosInvites",
            dependencies: [
                "ConvosInvitesCore",
                "ConvosAppData",
                .product(name: "XMTPiOS", package: "libxmtp"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ConvosInvites"
        ),
        .testTarget(
            name: "ConvosInvitesCoreTests",
            dependencies: ["ConvosInvitesCore"],
            path: "Tests/ConvosInvitesCoreTests"
        ),
        .testTarget(
            name: "ConvosInvitesTests",
            dependencies: ["ConvosInvites"],
            path: "Tests/ConvosInvitesTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
