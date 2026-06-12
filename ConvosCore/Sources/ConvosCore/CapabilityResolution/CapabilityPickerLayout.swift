import ConvosConnections
import Foundation

/// Snapshot of what the capability approval sheet should render for a given
/// `CapabilityRequest`. Pure value type — the SwiftUI view consumes this to draw the
/// right variant, and posts a chosen `Set<ProviderID>` back to the resolver via
/// `CapabilityRequestHandler.commit` on approve.
public struct CapabilityPickerLayout: Sendable, Equatable {
    public let request: CapabilityRequest
    public let variant: Variant
    public let providers: [ProviderSummary]
    public let defaultSelection: Set<ProviderID>
    /// Permission-bundle rows for the cloud providers on this card, one group
    /// per provider whose service exists in the backend catalog
    /// (`GET /v2/connections/services`). Empty when the catalog has no entry
    /// for any provider (or wasn't reachable) — the card then renders the
    /// pre-bundle provider rows only.
    public let serviceBundles: [ServiceBundles]

    public init(
        request: CapabilityRequest,
        variant: Variant,
        providers: [ProviderSummary],
        defaultSelection: Set<ProviderID>,
        serviceBundles: [ServiceBundles] = []
    ) {
        self.request = request
        self.variant = variant
        self.providers = providers
        self.defaultSelection = defaultSelection
        self.serviceBundles = serviceBundles
    }

    /// Bundle rows for one cloud provider, resolved against the services
    /// catalog at layout time (strings already localized for display).
    public struct ServiceBundles: Sendable, Equatable, Hashable {
        public let providerId: ProviderID
        public let serviceId: String
        public let serviceVersion: Int
        public let rows: [Row]

        public init(providerId: ProviderID, serviceId: String, serviceVersion: Int, rows: [Row]) {
            self.providerId = providerId
            self.serviceId = serviceId
            self.serviceVersion = serviceVersion
            self.rows = rows
        }

        public struct Row: Sendable, Equatable, Hashable {
            public let id: String
            public let title: String
            public let description: String
            public let defaultEnabled: Bool

            public init(id: String, title: String, description: String, defaultEnabled: Bool) {
                self.id = id
                self.title = title
                self.description = description
                self.defaultEnabled = defaultEnabled
            }
        }
    }

    public enum Variant: Sendable, Equatable {
        /// Variant 1 — exactly one linked provider. Default-approve confirmation card
        /// with "Use a different one?" disclosure expanding into Variant 2a/2b.
        case confirm
        /// Variant 2a — multiple linked providers, single-select. Renders for any write
        /// verb or for read on a non-federating subject.
        case singleSelect
        /// Variant 2b — multiple linked providers, multi-select. Only renders for read
        /// verbs on subjects with `allowsReadFederation == true`.
        case multiSelect
        /// Variant 3 — zero linked providers. The card doubles as a "Connect a calendar"
        /// entry point with one row per known provider option.
        case connectAndApprove
        /// Verb-only consent card. Surfaces when an existing resolution on the same
        /// subject (different verb) determines the answer, e.g. user already approved
        /// `device.calendar` reads and the agent now asks for writes — no picker needed,
        /// just "Allow Apple Calendar to write events?".
        case verbConsent
    }

    public struct ProviderSummary: Sendable, Equatable, Hashable {
        public let id: ProviderID
        public let displayName: String
        public let iconName: String
        public let subject: CapabilitySubject
        public let linked: Bool
        public let supportsCapability: Bool
        public let subjectNounPhrase: String?

        public init(
            id: ProviderID,
            displayName: String,
            iconName: String,
            subject: CapabilitySubject,
            linked: Bool,
            supportsCapability: Bool,
            subjectNounPhrase: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.iconName = iconName
            self.subject = subject
            self.linked = linked
            self.supportsCapability = supportsCapability
            self.subjectNounPhrase = subjectNounPhrase
        }
    }
}
