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
        "gmail",
        "googlecalendar",
        "googledocs",
    ]

    /// The subset that renders as connect/toggle rows in the V1 Connections
    /// UI — the App Settings list and the Conversation Info section shown
    /// when Abilities V2 is off. gmail and googledocs stay supported for
    /// capability resolution (the picker's CONNECT_AND_APPROVE path and
    /// inbound capability cards work in every mode) but surface as
    /// standalone connection rows only in the V2 Abilities UI.
    public static let v1CloudServiceIds: Set<String> = [
        "googlecalendar",
    ]

    public static func isSupported(_ kind: ConnectionKind) -> Bool {
        supportedDeviceKinds.contains(kind)
    }

    public static func isSupported(cloudServiceId: String) -> Bool {
        supportedCloudServiceIds.contains(cloudServiceId)
    }

    public static func isSupportedInV1(cloudServiceId: String) -> Bool {
        v1CloudServiceIds.contains(cloudServiceId)
    }
}
