// ConvosiOS
//
// iOS-specific implementations for the Convos app.
// This package contains platform-specific code that depends on UIKit and other iOS frameworks.
//
// To use ConvosiOS, you must initialize the platform providers during app startup:
//
// ```swift
// import ConvosCore
// import ConvosiOS
//
// @main
// struct ConvosApp: App {
//     init() {
//         // Initialize platform-specific providers
//         ConvosiOS.initialize()
//     }
// }
// ```

import Foundation

/// Initializes all iOS-specific platform providers.
///
/// Call this during app initialization (e.g., in AppDelegate or App.init())
/// before any ConvosCore functionality is used.
public enum ConvosiOS {
    /// Initializes all platform-specific providers for iOS.
    ///
    /// This sets up:
    /// - `PushNotificationRegistrar.shared` with `IOSPushNotificationRegistrar`
    /// - `DeviceInfo.shared` with `IOSDeviceInfo`
    /// - `ImageCompression.shared` with `IOSImageCompression`
    public static func initialize() {
        PushNotificationRegistrar.shared = IOSPushNotificationRegistrar()
        DeviceInfo.shared = IOSDeviceInfo()
        ImageCompression.shared = IOSImageCompression()
    }
}

// Re-export types from ConvosCore for convenience
@_exported import ConvosCore
