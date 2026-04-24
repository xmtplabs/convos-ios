// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// DTUPilot — the first Convos iOS pilot test that drives a local `dtu-server`
// subprocess via the XMTPDTU Swift SDK. This package is intentionally
// macOS-only: `DTUClient.spawn(...)` needs `Process`, which isn't available
// in the iOS simulator. The value delivered is proving the SDK is consumable
// from Convos's Swift ecosystem and can host the "conversation list sync +
// newest-message preview" scenario end-to-end with zero XMTP backend and zero
// Docker. See `DTUPilot/README.md` for the full run story.
//
// This package is intentionally isolated from the Convos app graph (no
// `ConvosCore` dep, no Xcode project entry). That way it can't regress the
// existing 59-unit-test baseline or pull XMTPiOS into builds that are
// otherwise clean of it.
let package = Package(
    name: "DTUPilot",
    platforms: [
        // macOS-only: the pilot drives a subprocess and doesn't run on iOS.
        // v12 matches what XMTPDTU publishes; bumping past that would serve
        // no purpose here.
        .macOS(.v12),
    ],
    products: [
        // No library product — this package only exports a test target. Keep
        // the graph tiny to minimize build friction for anyone running the
        // pilot from a fresh checkout.
    ],
    dependencies: [
        // Consume XMTPDTU as a local-path SwiftPM dependency. The sibling
        // `xmtp-dtu` workspace lives next to `convos-ios-task-A`, so the
        // relative path resolves reliably whether the caller runs `swift
        // test` from the DTUPilot directory (default) or a parent.
        //
        // Deliberately NOT depending on `ConvosCore` for v0.1: ConvosCore
        // targets iOS v26 / macOS v26 and pulls libxmtp + GRDB + Firebase +
        // Sentry, which is incompatible with this package's macOS v12 floor
        // and would turn the pilot into a 10+ minute fetch-and-build cycle.
        // The Stage 3 follow-up refactors ConvosCore's `MessagingClient`
        // injection seam so the pilot can target a clean protocol-surface
        // instead.
        .package(name: "XMTPDTU", path: "../../xmtp-dtu/clients/swift"),
    ],
    targets: [
        .testTarget(
            name: "DTUPilotTests",
            dependencies: [
                .product(name: "XMTPDTU", package: "XMTPDTU"),
            ],
            path: "Tests/DTUPilotTests"
        ),
    ]
)
