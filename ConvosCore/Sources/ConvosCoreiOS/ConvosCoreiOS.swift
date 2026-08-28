#if canImport(UIKit)
// ConvosCoreiOS
//
// iOS-specific implementations for the Convos app.
// This package contains platform-specific code that depends on UIKit and other iOS frameworks.
//
// Usage:
// ```swift
// import ConvosCore
// import ConvosCoreiOS
//
// @main
// struct ConvosApp: App {
//     let convos: ConvosClient
//
//     init() {
//         convos = ConvosClient.client(
//             environment: .production,
//             platformProviders: .iOS
//         )
//     }
// }
// ```

import ConvosConnections
import ConvosConnectionsHealth
import Foundation
import HealthKit
import UserNotifications

// MARK: - iOS Platform Providers Extension

extension PlatformProviders {
    /// Creates platform providers configured for iOS.
    ///
    /// This provides:
    /// - `IOSAppLifecycleProvider` for app lifecycle events
    /// - `IOSDeviceInfo` for device information
    /// - `IOSPushNotificationRegistrar` for push notification management
    ///
    /// Must be called from the main actor (typically during app initialization).
    @MainActor
    public static var iOS: PlatformProviders {
        iOS(deviceConnections: healthDeviceConnections)
    }

    /// App Clip variant: identical to `.iOS` but opts out of every device
    /// connection. App Clips cannot use HealthKit, and the clip has no
    /// connections UI.
    @MainActor
    public static var iOSAppClip: PlatformProviders {
        iOS(deviceConnections: .none)
    }

    @MainActor
    private static func iOS(deviceConnections: DeviceConnectionsBundle) -> PlatformProviders {
        let appLifecycle = IOSAppLifecycleProvider()
        let deviceInfo = IOSDeviceInfo()
        let pushNotificationRegistrar = IOSPushNotificationRegistrar()

        DeviceInfo.configure(deviceInfo)
        PushNotificationRegistrar.configure(pushNotificationRegistrar)
        ImageCompression.configure(IOSImageCompression())
        RichLinkMetadata.configure(IOSRichLinkMetadataProvider())

        return PlatformProviders(
            appLifecycle: appLifecycle,
            deviceInfo: deviceInfo,
            pushNotificationRegistrar: pushNotificationRegistrar,
            notificationCenter: UNUserNotificationCenter.current(),
            backgroundUploadManager: BackgroundUploadManager.shared,
            oauthSessionProvider: IOSOAuthSessionProvider(),
            deviceConnections: deviceConnections
        )
    }

    /// Health is the only device kind the app links. A single `HKHealthStore`
    /// backs the four background-delivery runtime implementations so anchors,
    /// observer queries, and delivery toggles all see the same store.
    private static var healthDeviceConnections: DeviceConnectionsBundle {
        let store = HKHealthStore()
        return DeviceConnectionsBundle(
            dataSources: [HealthDataSource()],
            dataSinks: [HealthDataSink()],
            health: HealthRuntimeImpls(
                backgroundDeliveryGateway: HKHealthStoreBackgroundDeliveryGateway(store: store),
                backfillReader: HKHealthStoreBackfillReader(store: store),
                deltaReader: HKHealthStoreDeltaReader(store: store),
                observerRegistrar: HKHealthStoreObserverRegistrar(store: store)
            )
        )
    }

    /// Creates platform providers configured for iOS app extensions (e.g., Notification Service Extension).
    ///
    /// Unlike `.iOS`, this does not require main actor isolation since extensions
    /// may initialize providers outside of the main actor context. Uses mock providers
    /// for components that aren't needed in extensions.
    public static var iOSExtension: PlatformProviders {
        PlatformProviders(
            appLifecycle: MockAppLifecycleProvider(),
            deviceInfo: MockDeviceInfoProvider(),
            pushNotificationRegistrar: MockPushNotificationRegistrarProvider(),
            notificationCenter: MockUserNotificationCenter(),
            // Extensions publish and read the local database; the streaming
            // sync engine costs memory an appex doesn't have (120 MB ceiling).
            startsStreamingServices: false
        )
    }
}

@_exported import ConvosCore
#endif
