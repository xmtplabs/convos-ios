import ConvosCore
import Foundation

/// CLI device info provider for macOS
public final class CLIDeviceInfoProvider: DeviceInfoProviding, Sendable {
    public let identifierForVendor: String?
    public let fallbackIdentifier: String
    public let deviceIdentifier: String
    public let osString: String

    public init() {
        // Try to get machine serial number for a stable identifier
        let serialNumber = Self.getMachineSerialNumber()

        self.identifierForVendor = serialNumber
        self.fallbackIdentifier = Self.getOrCreateFallbackIdentifier()
        self.deviceIdentifier = serialNumber ?? Self.getOrCreateFallbackIdentifier()
        self.osString = "macos"
    }

    /// Gets the machine serial number if available
    private static func getMachineSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        guard let serialNumber = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }
        return serialNumber
    }

    /// Gets or creates a persistent fallback identifier stored in user defaults
    private static func getOrCreateFallbackIdentifier() -> String {
        let key = "com.convos.cli.deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
