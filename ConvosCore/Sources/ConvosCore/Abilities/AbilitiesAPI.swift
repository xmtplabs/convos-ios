import Foundation

/// Wire models for the V2 abilities catalog served by `GET /v2/abilities`.
///
/// One response carries the full catalog crossed with the caller's
/// entitlement state. On an authoritative response every ability carries
/// `entitlement` as an object (entitled) or `null` (not entitled, or a
/// device-only caller). When the backend cannot derive entitlement state it
/// still serves the catalog with a top-level `entitlementsUnavailable: true`
/// and omits the `entitlement` key on every ability. Clients branch on the
/// flag, never on key presence, and keep last-known entitlement state; see
/// `CatalogResponse.keepingLastKnownEntitlements(from:)`.
public enum AbilitiesAPI {
    /// A localized string map keyed by language code. Always carries an
    /// "en" key (the guaranteed fallback); may carry more locales.
    public struct LocalizedText: Codable, Sendable, Hashable {
        public let values: [String: String]

        public init(values: [String: String]) {
            self.values = values
        }

        /// Convenience for fixtures and previews: an English-only map.
        public init(en: String) {
            self.values = ["en": en]
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.values = try container.decode([String: String].self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }

        /// Resolves for `locale` with the fallback chain
        /// `values[languageCode] ?? values["en"] ?? ""`.
        public func resolved(for locale: Locale = .current) -> String {
            if let code = locale.language.languageCode?.identifier, let value = values[code] {
                return value
            }
            return values["en"] ?? ""
        }
    }

    /// Optional per-platform icon URLs. Omitted by the backend until its
    /// asset delivery story lands; clients fall back to a local symbol.
    public struct AbilityIcon: Codable, Sendable, Hashable {
        public let iosUrl: String?
        public let androidUrl: String?

        public init(iosUrl: String? = nil, androidUrl: String? = nil) {
            self.iosUrl = iosUrl
            self.androidUrl = androidUrl
        }
    }

    /// How an entitlement gets authorized. Callback specifics stay
    /// backend-side; the client only needs to know whether an OAuth
    /// round-trip is involved.
    public enum AbilityAuthType: String, Codable, Sendable {
        case oauth
        case none
    }

    public struct AbilityAuth: Codable, Sendable, Hashable {
        public let type: AbilityAuthType

        public init(type: AbilityAuthType) {
            self.type = type
        }
    }

    /// One user-facing permission bundle inside an ability ("Events").
    public struct AbilityBundle: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let title: LocalizedText
        public let description: LocalizedText
        public let defaultEnabled: Bool

        public init(id: String, title: LocalizedText, description: LocalizedText, defaultEnabled: Bool) {
            self.id = id
            self.title = title
            self.description = description
            self.defaultEnabled = defaultEnabled
        }
    }

    /// Server-owned entitlement lifecycle status. The backend currently
    /// emits `pending_auth`, `active`, and `expired` only; `needs_reauth`
    /// (service-mediated revalidation) and `revoked` (explicit user
    /// revocation) are reserved and arrive with the entitlement tables.
    /// Unknown values decode as `.expired`, the safe floor, mirroring how
    /// the backend collapses unknown upstream states.
    public enum EntitlementStatus: String, Codable, Sendable {
        case pendingAuth = "pending_auth"
        case active = "active"
        case needsReauth = "needs_reauth"
        case expired = "expired"
        case revoked = "revoked"

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = EntitlementStatus(rawValue: raw) ?? .expired
        }
    }

    /// The caller's account-level binding for one ability. Clients only
    /// ever read `status`; they never derive it.
    public struct Entitlement: Codable, Sendable, Hashable {
        public let status: EntitlementStatus
        public let expiresAt: Date?
        /// Number of distinct conversations this entitlement is extended
        /// to. A bounded summary for the ability list and the re-auth
        /// nudge; per-conversation, per-agent detail comes from the
        /// per-conversation abilities endpoint.
        public let extensionCount: Int

        public init(status: EntitlementStatus, expiresAt: Date? = nil, extensionCount: Int = 0) {
            self.status = status
            self.expiresAt = expiresAt
            self.extensionCount = extensionCount
        }
    }

    /// One catalog entry crossed with the caller's entitlement state.
    public struct Ability: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        /// Per-ability version, bumped whenever anything about the served
        /// ability changes (staleness handling).
        public let version: Int
        public let displayName: LocalizedText
        public let subtitle: LocalizedText
        public let icon: AbilityIcon?
        public let auth: AbilityAuth
        public let bundles: [AbilityBundle]
        /// Object when entitled, `nil` when not entitled or when the
        /// response carries `entitlementsUnavailable`. Branch on the
        /// response flag, not on this key.
        public let entitlement: Entitlement?

        public init(
            id: String,
            version: Int,
            displayName: LocalizedText,
            subtitle: LocalizedText,
            icon: AbilityIcon? = nil,
            auth: AbilityAuth,
            bundles: [AbilityBundle],
            entitlement: Entitlement? = nil
        ) {
            self.id = id
            self.version = version
            self.displayName = displayName
            self.subtitle = subtitle
            self.icon = icon
            self.auth = auth
            self.bundles = bundles
            self.entitlement = entitlement
        }

        /// A copy of this ability with `entitlement` replaced.
        public func withEntitlement(_ entitlement: Entitlement?) -> Ability {
            Ability(
                id: id,
                version: version,
                displayName: displayName,
                subtitle: subtitle,
                icon: icon,
                auth: auth,
                bundles: bundles,
                entitlement: entitlement
            )
        }
    }

    /// The `GET /v2/abilities` response.
    public struct CatalogResponse: Codable, Sendable, Hashable {
        /// Bumped on any served-catalog change (manifests and bundles).
        public let catalogVersion: Int
        /// True when the backend could not derive entitlement state
        /// (upstream outage, incomplete upstream state). The abilities then
        /// carry no `entitlement` key at all and clients keep last-known
        /// entitlement state instead of rendering "not connected". Absent
        /// on the wire when false.
        public let entitlementsUnavailable: Bool
        public let abilities: [Ability]

        public init(catalogVersion: Int, entitlementsUnavailable: Bool = false, abilities: [Ability]) {
            self.catalogVersion = catalogVersion
            self.entitlementsUnavailable = entitlementsUnavailable
            self.abilities = abilities
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.catalogVersion = try container.decode(Int.self, forKey: .catalogVersion)
            self.entitlementsUnavailable = try container.decodeIfPresent(Bool.self, forKey: .entitlementsUnavailable) ?? false
            self.abilities = try container.decode([Ability].self, forKey: .abilities)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(catalogVersion, forKey: .catalogVersion)
            if entitlementsUnavailable {
                try container.encode(true, forKey: .entitlementsUnavailable)
            }
            try container.encode(abilities, forKey: .abilities)
        }

        /// Applies the availability contract: when this response carries
        /// `entitlementsUnavailable`, its abilities have no entitlement
        /// state, so entitlements from the last authoritative catalog are
        /// carried forward by ability id. Authoritative responses return
        /// unchanged. Callers store the merged result as their last-known
        /// state so back-to-back outages keep carrying it forward.
        public func keepingLastKnownEntitlements(from lastKnown: CatalogResponse?) -> CatalogResponse {
            guard entitlementsUnavailable, let lastKnown else { return self }
            let lastKnownEntitlements: [String: Entitlement] = lastKnown.abilities.reduce(into: [:]) { partial, ability in
                if let entitlement = ability.entitlement {
                    partial[ability.id] = entitlement
                }
            }
            guard !lastKnownEntitlements.isEmpty else { return self }
            let merged: [Ability] = abilities.map { (ability: Ability) -> Ability in
                guard let entitlement = lastKnownEntitlements[ability.id] else { return ability }
                return ability.withEntitlement(entitlement)
            }
            return CatalogResponse(catalogVersion: catalogVersion, entitlementsUnavailable: true, abilities: merged)
        }

        private enum CodingKeys: String, CodingKey {
            case catalogVersion
            case entitlementsUnavailable
            case abilities
        }
    }
}
