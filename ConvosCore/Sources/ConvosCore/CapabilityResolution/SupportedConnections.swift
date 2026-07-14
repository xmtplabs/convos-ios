import ConvosConnections
import Foundation

/// Allowlist of connections currently surfaced to users.
///
/// Drives both the picker registry (via `CapabilityProviderBootstrap`) and the
/// connections UI in App Settings / Conversation Info. Adding a new provider is
/// a non-breaking expansion — the reverse hides a previously-shown option, so
/// keep the rollout intentional.
public enum SupportedConnections {
    // Health is re-enabled for testing: the host links ConvosConnectionsHealth
    // (via ConvosCoreiOS) and injects the HealthKit runtime through
    // `PlatformProviders.iOS`. Every other device kind stays off; adding one
    // requires listing it here AND linking the matching per-kind product so
    // its Apple-framework symbols enter the binary.
    public static let supportedDeviceKinds: Set<ConnectionKind> = [.health]

    public static let supportedCloudServiceIds: Set<String> = [
        "googlecalendar",
    ]

    public static func isSupported(_ kind: ConnectionKind) -> Bool {
        supportedDeviceKinds.contains(kind)
    }

    public static func isSupported(cloudServiceId: String) -> Bool {
        supportedCloudServiceIds.contains(cloudServiceId)
    }
}
