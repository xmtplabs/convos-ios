// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosConnections",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Core library. All ship-worthy sources (Health, Calendar, Location, Contacts,
        // Photos, Music, Motion, HomeKit) plus every payload type including
        // `ScreenTimePayload`. Does NOT link FamilyControls.
        .library(
            name: "ConvosConnections",
            targets: ["ConvosConnections"]
        ),
        // Optional add-on for the Screen Time / Family Controls data source.
        //
        // Pulled out into its own product because the `com.apple.developer.family-controls`
        // entitlement requires Apple's explicit approval for App Store distribution (via a
        // form on the developer portal). Apps that can't yet ship with that entitlement
        // should depend on `ConvosConnections` alone. Once the entitlement is granted,
        // add this product to the app's dependencies and register a `ScreenTimeDataSource`
        // with your `ConnectionsManager`.
        .library(
            name: "ConvosConnectionsScreenTime",
            targets: ["ConvosConnectionsScreenTime"]
        ),
    ],
    targets: [
        .target(
            name: "ConvosConnections",
            path: "Sources/ConvosConnections"
        ),
        .target(
            name: "ConvosConnectionsScreenTime",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnectionsScreenTime"
        ),
        .testTarget(
            name: "ConvosConnectionsTests",
            dependencies: ["ConvosConnections"],
            path: "Tests/ConvosConnectionsTests"
        ),
        .testTarget(
            name: "ConvosConnectionsScreenTimeTests",
            dependencies: ["ConvosConnectionsScreenTime"],
            path: "Tests/ConvosConnectionsScreenTimeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
