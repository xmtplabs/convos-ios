// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// ConvosCoreDTU — the DTU-backed adapter that conforms `XMTPDTU.DTUClient`
// to ConvosCore's `MessagingClient` abstraction. Kept as a sibling package
// rather than a dependency on `ConvosCore/Package.swift` so the DTU adapter
// stays contained until the validation milestone is reviewed + approved.
//
// Platform floor:
//  - macOS v15: DTU spawn needs `Process` (macOS-only). The package is
//    effectively macOS-only today; the test target is where the actual
//    server subprocess is spun up.
//  - iOS v18 kept on the table for the future `DTUClient.connect(url:)`
//    path that points at a host / CI instance. For now only the macOS
//    target path is exercised in tests.
//
// This package depends on:
//  - ConvosCore (local path): provides the `MessagingClient` et al
//    protocols that this adapter conforms to.
//  - XMTPDTU (local path, via xmtp-dtu workspace sibling): the Swift SDK
//    that talks to a `dtu-server` subprocess. Deliberately NOT pinned as
//    a git dependency — the project rule is xmtp-dtu stays local-only
//    (publish policy in project memory).
let package = Package(
    name: "ConvosCoreDTU",
    platforms: [
        // Must be >= ConvosCore's floors (iOS v26 / macOS v26). The DTU
        // spawn path is macOS-only, but a ConvosCoreDTU library that
        // imports ConvosCore needs to match ConvosCore's deployment
        // targets for SwiftPM to accept the dependency.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "ConvosCoreDTU",
            targets: ["ConvosCoreDTU"]
        ),
    ],
    dependencies: [
        .package(path: "../ConvosCore"),
        // ConvosAppData lives beside ConvosCore in this workspace and
        // carries the `ConversationCustomMetadata` protobuf type that
        // writer-integration tests in this target need to encode
        // empty-metadata blobs. The ConvosCore library already depends
        // on it; we declare the dep explicitly so the test target can
        // `import ConvosAppData` without reaching through internal
        // transitive module names.
        .package(path: "../ConvosAppData"),
        .package(path: "../ConvosMessagingProtocols"),
        // XMTPDTU lives in a sibling `xmtp-dtu` workspace folder (see
        // project CLAUDE.md). Relative path anchors at the task-D clone
        // parent so `xmtp-dtu/clients/swift/` resolves cleanly.
        .package(name: "XMTPDTU", path: "../../xmtp-dtu/clients/swift"),
    ],
    targets: [
        .target(
            name: "ConvosCoreDTU",
            dependencies: [
                .product(name: "ConvosCore", package: "ConvosCore"),
                .product(name: "ConvosMessagingProtocols", package: "ConvosMessagingProtocols"),
                .product(name: "XMTPDTU", package: "XMTPDTU"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "ConvosCoreDTUTests",
            dependencies: [
                "ConvosCoreDTU",
                .product(name: "ConvosCore", package: "ConvosCore"),
                .product(name: "ConvosAppData", package: "ConvosAppData"),
                .product(name: "ConvosMessagingProtocols", package: "ConvosMessagingProtocols"),
                .product(name: "XMTPDTU", package: "XMTPDTU"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
