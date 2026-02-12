// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ConvosCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ConvosCore",
            targets: ["ConvosCore"]
        ),
        .library(
            name: "ConvosCoreiOS",
            targets: ["ConvosCoreiOS"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.5.0"),
        .package(
            url: "https://github.com/xmtp/libxmtp.git",
            revision: "ios-4.9.0-dev.6ecd439"
        ),
        .package(url: "https://github.com/tesseract-one/CSecp256k1.swift.git", from: "0.2.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.1"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.57.1"),
        .package(path: "../ConvosLogging"),
    ],
    targets: [
        .target(
            name: "ConvosCore",
            dependencies: [
                .product(name: "XMTPiOS", package: "libxmtp"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAppCheck", package: "firebase-ios-sdk"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "CSecp256k1", package: "CSecp256k1.swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "ConvosLogging", package: "ConvosLogging"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Define DEBUG - will be active based on Xcode's SWIFT_ACTIVE_COMPILATION_CONDITIONS
                .define("DEBUG", .when(configuration: .debug)),
                // Disable optimization for debug builds to enable proper debugging
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "ConvosCoreiOS",
            dependencies: [
                .target(name: "ConvosCore", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/ConvosCoreiOS",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("DEBUG", .when(configuration: .debug)),
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "ConvosCoreTests",
            dependencies: ["ConvosCore", "ConvosCoreiOS"]
        ),
    ]
)
