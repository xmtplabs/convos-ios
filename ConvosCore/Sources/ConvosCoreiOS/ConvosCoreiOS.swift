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

import Foundation

// MARK: - iOS Platform Providers Extension

extension PlatformProviders {
    /// Creates platform providers configured for iOS.
    ///
    /// This provides:
    /// - `IOSAppLifecycleProvider` for app lifecycle events
    /// - `IOSDeviceInfo` for device information
    /// - `IOSPushNotificationRegistrar` for push notification management
    ///
    /// Also sets up the legacy singleton accessors for backwards compatibility.
    public static var iOS: PlatformProviders {
        let appLifecycle = IOSAppLifecycleProvider()
        let deviceInfo = IOSDeviceInfo()
        let pushNotificationRegistrar = IOSPushNotificationRegistrar()

        // Configure legacy singletons for code that doesn't use dependency injection
        // (e.g., DebugView accessing PushNotificationRegistrar.token)
        DeviceInfo.configure(deviceInfo)
        PushNotificationRegistrar.configure(pushNotificationRegistrar)
        ImageCompression.configure(IOSImageCompression())

        return PlatformProviders(
            appLifecycle: appLifecycle,
            deviceInfo: deviceInfo,
            pushNotificationRegistrar: pushNotificationRegistrar
        )
    }
}

// Re-export types from ConvosCore for convenience
@_exported import ConvosCore
#endif
