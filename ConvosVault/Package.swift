// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosVault",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "ConvosVault",
            targets: ["ConvosVault"]
        ),
    ],
    dependencies: [
        .package(path: "../ConvosAppData"),
        .package(
            url: "https://github.com/xmtp/libxmtp.git",
            revision: "ios-4.9.0-dev.6ecd439"
        ),
    ],
    targets: [
        .target(
            name: "ConvosVault",
            dependencies: [
                .product(name: "ConvosAppData", package: "ConvosAppData"),
                .product(name: "XMTPiOS", package: "libxmtp"),
            ],
            path: "Sources/ConvosVault"
        ),
        .testTarget(
            name: "ConvosVaultTests",
            dependencies: ["ConvosVault"],
            path: "Tests/ConvosVaultTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
