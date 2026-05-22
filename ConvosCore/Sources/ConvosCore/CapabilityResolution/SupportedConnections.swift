import ConvosConnections
import Foundation

/// Allowlist of connections currently surfaced to users.
///
/// Drives both the picker registry (via `CapabilityProviderBootstrap`) and the
/// connections UI in App Settings / Conversation Info. Adding a new provider is
/// a non-breaking expansion — the reverse hides a previously-shown option, so
/// keep the rollout intentional.
public enum SupportedConnections {
    // v1 ships cloud-only (Google Calendar via Composio). No device kinds
    // surface in the picker or the conversation-info connections list.
    // The host (Convos main target) also doesn't link any per-kind
    // ConvosConnections product, so the corresponding Apple-framework
    // symbols don't enter the binary. Re-introduce a kind here AND link
    // the matching product in Convos's Package dependencies to bring it
    // back.
    public static let supportedDeviceKinds: Set<ConnectionKind> = []

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
