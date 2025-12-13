// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ConvosiOS",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ConvosiOS",
            targets: ["ConvosiOS"]
        ),
    ],
    dependencies: [
        .package(path: "../ConvosCore"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.62.2"),
    ],
    targets: [
        .target(
            name: "ConvosiOS",
            dependencies: [
                .product(name: "ConvosCore", package: "ConvosCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("DEBUG", .when(configuration: .debug)),
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
            ]
        ),
    ]
)
