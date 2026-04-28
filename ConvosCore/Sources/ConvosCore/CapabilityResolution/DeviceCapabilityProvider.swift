import ConvosConnections
import Foundation

/// `CapabilityProvider` adapter for a device-backed `ConnectionKind`. The wrapping is
/// intentional — `ConvosConnections` deliberately doesn't depend on ConvosCore (or on
/// `CapabilityProviderRegistry`), so the bridge from "this device exposes a calendar
/// sink" to "this `device.calendar` provider gets registered with the resolver" lives
/// here in ConvosCore.
public struct DeviceCapabilityProvider: CapabilityProvider, Sendable {
    public let id: ProviderID
    public let subject: CapabilitySubject
    public let displayName: String
    public let iconName: String
    public let capabilities: Set<ConnectionCapability>
    private let linkedProvider: @Sendable () async -> Bool
    private let availableProvider: @Sendable () async -> Bool

    public init(
        id: ProviderID,
        subject: CapabilitySubject,
        displayName: String,
        iconName: String,
        capabilities: Set<ConnectionCapability>,
        linkedByUser: @escaping @Sendable () async -> Bool,
        available: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.id = id
        self.subject = subject
        self.displayName = displayName
        self.iconName = iconName
        self.capabilities = capabilities
        self.linkedProvider = linkedByUser
        self.availableProvider = available
    }

    public var linkedByUser: Bool { get async { await linkedProvider() } }
    public var available: Bool { get async { await availableProvider() } }
}

public extension DeviceCapabilityProvider {
    /// Subject that a given `ConnectionKind` routes to via the `defaultSpecs` table.
    /// `nil` for kinds that aren't user-facing subjects (`.motion`).
    static func subject(for kind: ConnectionKind) -> CapabilitySubject? {
        defaultSpecs.first { $0.kind == kind }?.subject
    }

    /// Stable `ProviderID` for the local device's representation of a kind. The string
    /// shape (`device.<kind.rawValue>`) is deliberate — equals what `defaultSpecs`
    /// publishes under the same kind.
    static func providerId(for kind: ConnectionKind) -> ProviderID {
        ProviderID(rawValue: "device.\(kind.rawValue)")
    }

    /// Static catalog mapping each routable `ConnectionKind` to the user-facing subject,
    /// the verbs the device subsystem can fulfill, and a stable `ProviderID`.
    ///
    /// `nil` for kinds that don't correspond to a `CapabilitySubject` (e.g. `.motion`,
    /// which is a sensor primitive but not a thing an agent would ask the user to "grant
    /// access to"). Those kinds register as data sources for internal use only.
    struct Spec: Sendable {
        public let kind: ConnectionKind
        public let id: ProviderID
        public let subject: CapabilitySubject
        public let displayName: String
        public let iconName: String
        public let capabilities: Set<ConnectionCapability>
    }

    /// Default specs covering every ConnectionKind that maps to a user-facing subject.
    /// Hosts can override by passing custom specs to the bootstrap helper.
    static let defaultSpecs: [Spec] = [
        Spec(
            kind: .calendar,
            id: ProviderID(rawValue: "device.calendar"),
            subject: .calendar,
            displayName: "Apple Calendar",
            iconName: "calendar",
            capabilities: [.read, .writeCreate, .writeUpdate, .writeDelete]
        ),
        Spec(
            kind: .contacts,
            id: ProviderID(rawValue: "device.contacts"),
            subject: .contacts,
            displayName: "Apple Contacts",
            iconName: "person.crop.circle",
            capabilities: [.read, .writeCreate, .writeUpdate, .writeDelete]
        ),
        Spec(
            kind: .photos,
            id: ProviderID(rawValue: "device.photos"),
            subject: .photos,
            displayName: "Apple Photos",
            iconName: "photo.on.rectangle",
            capabilities: [.read, .writeCreate, .writeDelete]
        ),
        Spec(
            kind: .health,
            id: ProviderID(rawValue: "device.health"),
            subject: .fitness,
            displayName: "Apple Health",
            iconName: "heart.text.square",
            capabilities: [.read, .writeCreate]
        ),
        Spec(
            kind: .music,
            id: ProviderID(rawValue: "device.music"),
            subject: .music,
            displayName: "Apple Music",
            iconName: "music.note",
            capabilities: [.read, .writeCreate, .writeUpdate]
        ),
        Spec(
            kind: .location,
            id: ProviderID(rawValue: "device.location"),
            subject: .location,
            displayName: "Location",
            iconName: "location",
            capabilities: [.read]
        ),
        Spec(
            kind: .homeKit,
            id: ProviderID(rawValue: "device.home_kit"),
            subject: .home,
            displayName: "HomeKit",
            iconName: "house",
            capabilities: [.read, .writeCreate, .writeUpdate]
        ),
        Spec(
            kind: .screenTime,
            id: ProviderID(rawValue: "device.screen_time"),
            subject: .screenTime,
            displayName: "Screen Time",
            iconName: "hourglass",
            capabilities: [.read, .writeCreate, .writeUpdate, .writeDelete]
        ),
        // .motion intentionally has no spec — sensor primitive, not a user-facing
        // subject. Agents asking for `.fitness` route to `.health` (or a cloud fitness
        // provider).
    ]
}
