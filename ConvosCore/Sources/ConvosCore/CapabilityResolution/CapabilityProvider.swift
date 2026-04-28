import ConvosConnections
import Foundation

/// Provider — a concrete way to fulfill a `CapabilitySubject`. Both `ConvosConnections`
/// (device sources) and the cloud-OAuth subsystem register one provider per linked
/// service/permission.
public protocol CapabilityProvider: Sendable {
    var id: ProviderID { get }
    var subject: CapabilitySubject { get }

    /// User-visible display name ("Apple Calendar", "Google Calendar", "Strava").
    var displayName: String { get }

    /// SF Symbol name used in picker / confirmation cards.
    var iconName: String { get }

    /// Which capability verbs this provider supports. Independent of the subject's
    /// federation flag — a Strava-style read-only provider just publishes `[.read]`.
    var capabilities: Set<ConnectionCapability> { get }

    /// Whether the user has the credentials/permission for this provider right now.
    /// `true` for device providers when the iOS framework permission is granted; `true`
    /// for cloud providers when the OAuth grant is active (and not expired).
    var linkedByUser: Bool { get async }
}

/// Emitted on `CapabilityProviderRegistry.providerChanges` to drive reactive UI refresh
/// (e.g. the picker card subscribes so it can update in place when the user taps "Connect"
/// and completes OAuth).
public enum ProviderChange: Sendable, Equatable {
    case added(ProviderID)
    case removed(ProviderID)
    case linkedStateChanged(ProviderID)
}
