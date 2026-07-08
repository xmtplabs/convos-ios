#if canImport(UIKit)
import Foundation
import UIKit

/// Resolves the best available user-facing name for this device.
///
/// Since iOS 16, `UIDevice.current.name` returns the generic model string
/// ("iPhone") instead of the user-assigned name ("Jarod's iPhone") unless
/// the app carries the `com.apple.developer.device-information.
/// user-assigned-device-name` entitlement, which requires Apple approval.
/// Until that entitlement is granted, pairing surfaces would label every
/// physical device "iPhone". This helper falls back to the marketing model
/// name ("iPhone 16 Pro") derived from the hardware identifier so the
/// pairing prompt and device list can at least distinguish models.
/// Simulators return their simulator name from `UIDevice.current.name`
/// and never hit the fallback.
public enum DeviceModelName {
    /// The user-assigned device name when available, otherwise the
    /// marketing model name, otherwise whatever `UIDevice.current.name`
    /// returned.
    @MainActor
    public static func userFacingDeviceName() -> String {
        let name = UIDevice.current.name
        guard isGenericModelString(name, model: UIDevice.current.model) else {
            return name
        }
        return marketingName(forMachineIdentifier: currentMachineIdentifier()) ?? name
    }

    /// Whether `name` is the privacy-redacted generic model string rather
    /// than a user-assigned name. Redacted names equal `UIDevice.model`
    /// ("iPhone", "iPad"); any other value came from the user or the
    /// simulator.
    static func isGenericModelString(_ name: String, model: String) -> Bool {
        name == model || Constant.genericModelStrings.contains(name)
    }

    /// Hardware identifier like "iPhone17,1". On simulators the uname
    /// machine field is the host architecture, so the simulator's model
    /// identifier env var takes precedence.
    static func currentMachineIdentifier() -> String {
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineBytes: [UInt8] = withUnsafeBytes(of: &systemInfo.machine) { (buffer: UnsafeRawBufferPointer) -> [UInt8] in
            Array(buffer.prefix(while: { $0 != 0 }))
        }
        return String(bytes: machineBytes, encoding: .utf8) ?? ""
    }

    /// Marketing name for a hardware identifier, nil when unknown (new
    /// models ship faster than this table updates; callers degrade to the
    /// generic name).
    static func marketingName(forMachineIdentifier identifier: String) -> String? {
        Constant.marketingNames[identifier]
    }

    private enum Constant {
        static let genericModelStrings: Set<String> = ["iPhone", "iPad", "iPod touch"]

        /// Devices new enough to run the app's minimum OS.
        static let marketingNames: [String: String] = [
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            "iPhone18,5": "iPhone 17e",
        ]
    }
}
#endif
