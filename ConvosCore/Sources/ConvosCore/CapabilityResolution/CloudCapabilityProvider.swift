import ConvosConnections
import Foundation

/// `CapabilityProvider` adapter for a cloud OAuth `CloudConnection`. Constructed once
/// per linked service; the bootstrap helper registers it on link and unregisters on
/// unlink.
public struct CloudCapabilityProvider: CapabilityProvider, Sendable {
    public let id: ProviderID
    public let serviceId: String
    public let subject: CapabilitySubject
    public let displayName: String
    public let iconName: String
    public let capabilities: Set<ConnectionCapability>
    /// Snapshot of `CloudConnection.status == .active` at provider construction time.
    /// `CloudConnectionManager` re-registers (or unregisters) on grant rotation, so the
    /// registry always carries a fresh provider.
    public let linkedSnapshot: Bool

    public init(
        id: ProviderID,
        serviceId: String,
        subject: CapabilitySubject,
        displayName: String,
        iconName: String,
        capabilities: Set<ConnectionCapability>,
        linked: Bool
    ) {
        self.id = id
        self.serviceId = serviceId
        self.subject = subject
        self.displayName = displayName
        self.iconName = iconName
        self.capabilities = capabilities
        self.linkedSnapshot = linked
    }

    public var linkedByUser: Bool { get async { linkedSnapshot } }
    public var available: Bool { get async { true } }
}

public extension CloudCapabilityProvider {
    /// Mapping from a Composio `serviceId` to the user-facing subject. Conservative — the
    /// bootstrap helper falls back to ignoring services that aren't in the table, since
    /// publishing an unrouted provider would just confuse the picker.
    static let serviceSubjectMap: [String: CapabilitySubject] = [
        "google_calendar": .calendar,
        "google_drive": .photos,
        "microsoft_outlook": .calendar,
        "google_contacts": .contacts,
        "strava": .fitness,
        "fitbit": .fitness,
        "spotify": .music,
        "google_tasks": .tasks,
        "todoist": .tasks,
        "gmail": .mail,
    ]

    /// Default capability lists per service. Approximate for v1 — agents that hit a verb
    /// not actually supported by Composio's tool catalog get a runtime error from the
    /// router; the manifest just declares "we'd allow you to ask."
    static let serviceCapabilitiesMap: [String: Set<ConnectionCapability>] = [
        "google_calendar": [.read, .writeCreate, .writeUpdate, .writeDelete],
        "microsoft_outlook": [.read, .writeCreate, .writeUpdate, .writeDelete],
        "google_drive": [.read, .writeCreate, .writeUpdate, .writeDelete],
        "google_contacts": [.read, .writeCreate, .writeUpdate, .writeDelete],
        "strava": [.read],
        "fitbit": [.read],
        "spotify": [.read, .writeCreate, .writeUpdate],
        "google_tasks": [.read, .writeCreate, .writeUpdate, .writeDelete],
        "todoist": [.read, .writeCreate, .writeUpdate, .writeDelete],
        "gmail": [.read, .writeCreate],
    ]

    /// Build a provider from a `CloudConnection`, or `nil` if its `serviceId` isn't in
    /// the subject map (in which case it's not surfaced to agents).
    static func from(_ connection: CloudConnection) -> CloudCapabilityProvider? {
        guard let subject = serviceSubjectMap[connection.serviceId] else { return nil }
        let capabilities = serviceCapabilitiesMap[connection.serviceId] ?? [.read]
        return CloudCapabilityProvider(
            id: ProviderID(rawValue: "composio.\(connection.serviceId)"),
            serviceId: connection.serviceId,
            subject: subject,
            displayName: connection.serviceName,
            // Picker view supplies its own icon from `CloudConnectionServiceCatalog`;
            // the manifest carries an SF Symbol so a non-iOS reader has something to
            // render. "link" is the universal fallback.
            iconName: "link",
            capabilities: capabilities,
            linked: connection.status == .active
        )
    }
}
