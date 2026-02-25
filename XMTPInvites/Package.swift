// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "XMTPInvites",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "XMTPInvites",
            targets: ["XMTPInvites"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/tesseract-one/CSecp256k1.swift.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "XMTPInvites",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "CSecp256k1", package: "CSecp256k1.swift"),
            ],
            path: "Sources/XMTPInvites"
        ),
        .testTarget(
            name: "XMTPInvitesTests",
            dependencies: ["XMTPInvites"],
            path: "Tests/XMTPInvitesTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
