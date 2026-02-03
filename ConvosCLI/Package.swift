// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConvosCLI",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "convos", targets: ["ConvosCLI"]),
    ],
    dependencies: [
        .package(path: "../ConvosCore"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/rensbreur/SwiftTUI", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "ConvosCLI",
            dependencies: [
                .product(name: "ConvosCore", package: "ConvosCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
