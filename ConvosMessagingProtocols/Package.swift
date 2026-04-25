// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConvosMessagingProtocols",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ConvosMessagingProtocols",
            targets: ["ConvosMessagingProtocols"]
        )
    ],
    targets: [
        .target(
            name: "ConvosMessagingProtocols",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
