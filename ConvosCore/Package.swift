// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ConvosCore",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ConvosCore",
            targets: ["ConvosCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.5.0"),
        .package(url: "https://github.com/xmtp/xmtp-ios.git", exact: "4.7.0-dev.ea4f7e8"),
        .package(url: "https://github.com/tesseract-one/CSecp256k1.swift.git", from: "0.2.0"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.62.2"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.1"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.57.1"),
        .package(path: "../ConvosLogging"),
    ],
    targets: [
        .target(
            name: "ConvosCore",
            dependencies: [
                .product(name: "XMTPiOS", package: "xmtp-ios"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAppCheck", package: "firebase-ios-sdk"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "CSecp256k1", package: "CSecp256k1.swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "ConvosLogging", package: "ConvosLogging"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Define DEBUG - will be active based on Xcode's SWIFT_ACTIVE_COMPILATION_CONDITIONS
                .define("DEBUG", .when(configuration: .debug)),
                // Disable optimization for debug builds to enable proper debugging
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
            ]
        ),
        .testTarget(
            name: "ConvosCoreTests",
            dependencies: ["ConvosCore"]
        ),
    ]
)
