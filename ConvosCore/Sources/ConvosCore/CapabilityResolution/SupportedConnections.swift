import ConvosConnections
import Foundation

/// Allowlist of connections currently surfaced to users.
///
/// Drives both the picker registry (via `CapabilityProviderBootstrap`) and the
/// connections UI in App Settings / Conversation Info. Adding a new provider is
/// a non-breaking expansion — the reverse hides a previously-shown option, so
/// keep the rollout intentional.
public enum SupportedConnections {
    public static let supportedDeviceKinds: Set<ConnectionKind> = [
        .health,
    ]

    public static let supportedCloudServiceIds: Set<String> = [
        "google_calendar",
    ]

    public static func isSupported(_ kind: ConnectionKind) -> Bool {
        supportedDeviceKinds.contains(kind)
    }

    public static func isSupported(cloudServiceId: String) -> Bool {
        supportedCloudServiceIds.contains(cloudServiceId)
    }
}
