import ConvosCore
import Foundation

/// Factory for creating CLI-specific platform providers
extension PlatformProviders {
    /// Creates platform providers configured for CLI usage
    public static var cli: PlatformProviders {
        PlatformProviders(
            appLifecycle: CLIAppLifecycleProvider(),
            deviceInfo: CLIDeviceInfoProvider(),
            pushNotificationRegistrar: CLIPushNotificationRegistrar()
        )
    }
}
