// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConvosConnections",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Core / umbrella library. Protocols, value types (payloads, action
        // schemas), the ConnectionsManager actor, payload codecs, debug view,
        // and the in-memory stores. Imports only Foundation; no Apple
        // device frameworks. The host links this and its `ConvosConnections`
        // import still works exactly as before -- it just no longer pulls
        // any HealthKit / EventKit / CoreLocation / CoreMotion / Contacts /
        // MediaPlayer / HomeKit / Photos symbols into the binary.
        .library(name: "ConvosConnections", targets: ["ConvosConnections"]),

        // Per-kind device data-source products. Each one is opt-in; the host
        // adds the product to its target's dependencies only when it
        // intends to surface that kind in the picker / invocation runtime.
        // Apps that ship cloud-only (e.g. v1: Google Calendar via Composio)
        // depend on none of these and the corresponding Apple-framework
        // symbols never enter the binary.
        .library(name: "ConvosConnectionsCalendar", targets: ["ConvosConnectionsCalendar"]),
        .library(name: "ConvosConnectionsContacts", targets: ["ConvosConnectionsContacts"]),
        .library(name: "ConvosConnectionsHealth", targets: ["ConvosConnectionsHealth"]),
        .library(name: "ConvosConnectionsHomeKit", targets: ["ConvosConnectionsHomeKit"]),
        .library(name: "ConvosConnectionsLocation", targets: ["ConvosConnectionsLocation"]),
        .library(name: "ConvosConnectionsMotion", targets: ["ConvosConnectionsMotion"]),
        .library(name: "ConvosConnectionsMusic", targets: ["ConvosConnectionsMusic"]),
        .library(name: "ConvosConnectionsPhotos", targets: ["ConvosConnectionsPhotos"]),

        // Screen Time / Family Controls remains a separately-gated product;
        // the entitlement (`com.apple.developer.family-controls`) requires
        // Apple approval before App Store distribution.
        .library(name: "ConvosConnectionsScreenTime", targets: ["ConvosConnectionsScreenTime"]),
    ],
    targets: [
        .target(
            name: "ConvosConnections",
            path: "Sources/ConvosConnections",
            // Per-kind device data sources live in subfolders that are
            // compiled as their own targets below. Excluding them here is
            // what prevents the umbrella target -- and any host that imports
            // only `ConvosConnections` -- from pulling in their Apple
            // framework imports.
            exclude: ["DataSources"]
        ),
        .target(
            name: "ConvosConnectionsCalendar",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Calendar"
        ),
        .target(
            name: "ConvosConnectionsContacts",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Contacts"
        ),
        .target(
            name: "ConvosConnectionsHealth",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Health"
        ),
        .target(
            name: "ConvosConnectionsHomeKit",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Home"
        ),
        .target(
            name: "ConvosConnectionsLocation",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Location"
        ),
        .target(
            name: "ConvosConnectionsMotion",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Motion"
        ),
        .target(
            name: "ConvosConnectionsMusic",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Music"
        ),
        .target(
            name: "ConvosConnectionsPhotos",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnections/DataSources/Photos"
        ),
        .target(
            name: "ConvosConnectionsScreenTime",
            dependencies: ["ConvosConnections"],
            path: "Sources/ConvosConnectionsScreenTime"
        ),
        .testTarget(
            name: "ConvosConnectionsTests",
            dependencies: [
                "ConvosConnections",
                "ConvosConnectionsCalendar",
                "ConvosConnectionsContacts",
                "ConvosConnectionsHealth",
                "ConvosConnectionsHomeKit",
                "ConvosConnectionsLocation",
                "ConvosConnectionsMotion",
                "ConvosConnectionsMusic",
                "ConvosConnectionsPhotos",
            ],
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
