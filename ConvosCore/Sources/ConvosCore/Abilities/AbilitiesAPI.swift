import Foundation

/// Wire models for the V2 abilities catalog served by `GET /v2/abilities`,
/// mirroring `docs/schemas/abilities.schema.json` strictly in both
/// directions.
///
/// One response carries the full catalog crossed with the caller's
/// entitlement state. On an authoritative response every ability carries
/// `entitlement` as an object (entitled) or explicit `null` (not entitled,
/// or a device-only caller). When the backend cannot derive entitlement
/// state it still serves the catalog with a top-level
/// `entitlementsUnavailable: true` and omits the `entitlement` key on every
/// ability. The null-vs-absent distinction is preserved as
/// `EntitlementState` and the schema's flag/key coherence invariant is
/// validated on decode and reproduced on encode. Clients branch on the
/// flag, never on key presence; last-known state handling lives in
/// `AbilitiesCatalog`.
///
/// Strictness is bidirectional: the public initializers enforce the same
/// invariants decoding does (throwing `WireValidationError`), so a
/// schema-invalid response can neither be decoded nor constructed
/// programmatically and encoded.
public enum AbilitiesAPI {
    /// Typed failures thrown by the wire models' public initializers,
    /// which enforce the same schema invariants decoding does.
    public enum WireValidationError: Error, Sendable, Equatable {
        /// A localized string map without the required "en" key.
        case missingEnglishText
        /// An icon URL string that does not parse as a URL with a scheme.
        case invalidIconUrl(String)
        /// A negative per-ability version.
        case negativeVersion(Int)
        /// A negative catalog version.
        case negativeCatalogVersion(Int)
        /// A negative entitlement extension count.
        case negativeExtensionCount(Int)
        /// The flag/key coherence invariant: under
        /// `entitlementsUnavailable` every ability must be `.unknown`;
        /// authoritative responses must carry no `.unknown` ability.
        case incoherentEntitlementState
    }

    /// A localized string map keyed by language code. The schema requires
    /// the "en" key (the guaranteed fallback); decoding and programmatic
    /// construction both reject maps without it.
    public struct LocalizedText: Codable, Sendable, Hashable {
        public let values: [String: String]

        public init(values: [String: String]) throws {
            guard values["en"] != nil else {
                throw WireValidationError.missingEnglishText
            }
            self.values = values
        }

        /// Convenience for fixtures and previews: an English-only map.
        public init(en: String) {
            self.values = ["en": en]
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let decoded = try container.decode([String: String].self)
            guard decoded["en"] != nil else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Localized string map must carry an \"en\" key"
                )
            }
            self.values = decoded
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

    /// Per-platform icon URLs. The object itself is optional (the backend
    /// omits it until its asset story lands; clients fall back to a local
    /// symbol), but when present the schema requires both URLs, and both
    /// must parse as URLs with a scheme -- on decode and on construction.
    public struct AbilityIcon: Codable, Sendable, Hashable {
        public let iosUrl: String
        public let androidUrl: String

        public init(iosUrl: String, androidUrl: String) throws {
            guard Self.isValidUrl(iosUrl) else {
                throw WireValidationError.invalidIconUrl(iosUrl)
            }
            guard Self.isValidUrl(androidUrl) else {
                throw WireValidationError.invalidIconUrl(androidUrl)
            }
            self.iosUrl = iosUrl
            self.androidUrl = androidUrl
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let iosUrl = try container.decode(String.self, forKey: .iosUrl)
            guard Self.isValidUrl(iosUrl) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .iosUrl,
                    in: container,
                    debugDescription: "iosUrl must be a valid URL"
                )
            }
            let androidUrl = try container.decode(String.self, forKey: .androidUrl)
            guard Self.isValidUrl(androidUrl) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .androidUrl,
                    in: container,
                    debugDescription: "androidUrl must be a valid URL"
                )
            }
            self.iosUrl = iosUrl
            self.androidUrl = androidUrl
        }

        private static func isValidUrl(_ urlString: String) -> Bool {
            guard let url = URL(string: urlString), url.scheme != nil else { return false }
            return true
        }

        private enum CodingKeys: String, CodingKey {
            case iosUrl
            case androidUrl
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
    /// Unknown values collapse to `.expired` -- the safe floor, mirroring
    /// how the backend collapses unknown upstream states -- and the
    /// collapse is logged so new statuses surface in diagnostics instead
    /// of disappearing silently.
    public enum EntitlementStatus: String, Codable, Sendable {
        case pendingAuth = "pending_auth"
        case active = "active"
        case needsReauth = "needs_reauth"
        case expired = "expired"
        case revoked = "revoked"

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let known = EntitlementStatus(rawValue: raw) {
                self = known
            } else {
                Log.warning("Unknown entitlement status \"\(raw)\" collapsed to expired")
                self = .expired
            }
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

        public init(status: EntitlementStatus, expiresAt: Date? = nil, extensionCount: Int = 0) throws {
            guard extensionCount >= 0 else {
                throw WireValidationError.negativeExtensionCount(extensionCount)
            }
            self.status = status
            self.expiresAt = expiresAt
            self.extensionCount = extensionCount
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.status = try container.decode(EntitlementStatus.self, forKey: .status)
            self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
            let count = try container.decode(Int.self, forKey: .extensionCount)
            guard count >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .extensionCount,
                    in: container,
                    debugDescription: "extensionCount must be >= 0"
                )
            }
            self.extensionCount = count
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case expiresAt
            case extensionCount
        }
    }

    /// The three wire states of an ability's `entitlement` key: an object
    /// (entitled), explicit `null` (authoritatively not entitled), or the
    /// key omitted entirely (only legal under `entitlementsUnavailable`;
    /// state is unknown and clients must not render "not connected").
    public enum EntitlementState: Sendable, Hashable {
        case entitled(Entitlement)
        case notEntitled
        case unknown
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
        /// The decoded `entitlement` key, with null-vs-absent preserved.
        public let entitlementState: EntitlementState

        /// The entitlement object when entitled, `nil` otherwise. Only
        /// safe for display detail; classification must switch on
        /// `entitlementState` so unknown is never read as not entitled.
        public var entitlement: Entitlement? {
            guard case .entitled(let entitlement) = entitlementState else { return nil }
            return entitlement
        }

        public init(
            id: String,
            version: Int,
            displayName: LocalizedText,
            subtitle: LocalizedText,
            icon: AbilityIcon? = nil,
            auth: AbilityAuth,
            bundles: [AbilityBundle],
            entitlementState: EntitlementState = .notEntitled
        ) throws {
            guard version >= 0 else {
                throw WireValidationError.negativeVersion(version)
            }
            self.id = id
            self.version = version
            self.displayName = displayName
            self.subtitle = subtitle
            self.icon = icon
            self.auth = auth
            self.bundles = bundles
            self.entitlementState = entitlementState
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            let version = try container.decode(Int.self, forKey: .version)
            guard version >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "version must be >= 0"
                )
            }
            self.version = version
            self.displayName = try container.decode(LocalizedText.self, forKey: .displayName)
            self.subtitle = try container.decode(LocalizedText.self, forKey: .subtitle)
            self.icon = try container.decodeIfPresent(AbilityIcon.self, forKey: .icon)
            self.auth = try container.decode(AbilityAuth.self, forKey: .auth)
            self.bundles = try container.decode([AbilityBundle].self, forKey: .bundles)
            if container.contains(.entitlement) {
                if try container.decodeNil(forKey: .entitlement) {
                    self.entitlementState = .notEntitled
                } else {
                    self.entitlementState = .entitled(try container.decode(Entitlement.self, forKey: .entitlement))
                }
            } else {
                self.entitlementState = .unknown
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(version, forKey: .version)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(subtitle, forKey: .subtitle)
            try container.encodeIfPresent(icon, forKey: .icon)
            try container.encode(auth, forKey: .auth)
            try container.encode(bundles, forKey: .bundles)
            switch entitlementState {
            case .entitled(let entitlement):
                try container.encode(entitlement, forKey: .entitlement)
            case .notEntitled:
                try container.encodeNil(forKey: .entitlement)
            case .unknown:
                break
            }
        }

        /// Non-validating path for copies of an already-validated ability:
        /// swapping the entitlement state cannot violate any per-ability
        /// invariant, so no throwing round-trip is needed.
        private init(copying other: Ability, entitlementState: EntitlementState) {
            self.id = other.id
            self.version = other.version
            self.displayName = other.displayName
            self.subtitle = other.subtitle
            self.icon = other.icon
            self.auth = other.auth
            self.bundles = other.bundles
            self.entitlementState = entitlementState
        }

        /// A copy of this ability with `entitlementState` replaced.
        public func withEntitlementState(_ entitlementState: EntitlementState) -> Ability {
            Ability(copying: self, entitlementState: entitlementState)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case version
            case displayName
            case subtitle
            case icon
            case auth
            case bundles
            case entitlement
        }
    }

    /// The `GET /v2/abilities` response. Pure wire shape: decoding
    /// validates the schema's flag/key coherence invariant and encoding
    /// reproduces it, so a merged catalog (which can carry both the
    /// staleness marker and carried-forward entitlements) is deliberately
    /// a different type (`AbilitiesCatalog`), never re-encoded as a
    /// response.
    public struct CatalogResponse: Codable, Sendable, Hashable {
        /// Bumped on any served-catalog change (manifests and bundles).
        public let catalogVersion: Int
        /// True when the backend could not derive entitlement state
        /// (upstream outage, incomplete upstream state). Every ability
        /// then omits its `entitlement` key. On the wire the flag is
        /// present (always `true`) or absent, never `false`.
        public let entitlementsUnavailable: Bool
        public let abilities: [Ability]

        public init(catalogVersion: Int, entitlementsUnavailable: Bool = false, abilities: [Ability]) throws {
            guard catalogVersion >= 0 else {
                throw WireValidationError.negativeCatalogVersion(catalogVersion)
            }
            try Self.validateCoherence(entitlementsUnavailable: entitlementsUnavailable, abilities: abilities)
            self.catalogVersion = catalogVersion
            self.entitlementsUnavailable = entitlementsUnavailable
            self.abilities = abilities
        }

        /// The schema's flag/key coherence invariant, shared by the public
        /// initializer and decoding.
        private static func validateCoherence(entitlementsUnavailable: Bool, abilities: [Ability]) throws {
            if entitlementsUnavailable {
                guard abilities.allSatisfy({ $0.entitlementState == .unknown }) else {
                    throw WireValidationError.incoherentEntitlementState
                }
            } else {
                guard abilities.allSatisfy({ $0.entitlementState != .unknown }) else {
                    throw WireValidationError.incoherentEntitlementState
                }
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .catalogVersion)
            guard version >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .catalogVersion,
                    in: container,
                    debugDescription: "catalogVersion must be >= 0"
                )
            }
            self.catalogVersion = version
            if container.contains(.entitlementsUnavailable) {
                // Explicit null is not the same as absent: the wire flag is
                // present-true or absent, never null or false.
                guard try !container.decodeNil(forKey: .entitlementsUnavailable) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entitlementsUnavailable,
                        in: container,
                        debugDescription: "entitlementsUnavailable must not be null; the wire is present-true or absent"
                    )
                }
                let flag = try container.decode(Bool.self, forKey: .entitlementsUnavailable)
                guard flag else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entitlementsUnavailable,
                        in: container,
                        debugDescription: "entitlementsUnavailable, when present, must be true"
                    )
                }
                self.entitlementsUnavailable = true
            } else {
                self.entitlementsUnavailable = false
            }
            self.abilities = try container.decode([Ability].self, forKey: .abilities)
            if entitlementsUnavailable {
                guard abilities.allSatisfy({ $0.entitlementState == .unknown }) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .abilities,
                        in: container,
                        debugDescription: "Under entitlementsUnavailable no ability may carry an entitlement key"
                    )
                }
            } else {
                guard abilities.allSatisfy({ $0.entitlementState != .unknown }) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .abilities,
                        in: container,
                        debugDescription: "Authoritative responses require an entitlement key (object or null) on every ability"
                    )
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(catalogVersion, forKey: .catalogVersion)
            if entitlementsUnavailable {
                try container.encode(true, forKey: .entitlementsUnavailable)
            }
            try container.encode(abilities, forKey: .abilities)
        }

        private enum CodingKeys: String, CodingKey {
            case catalogVersion
            case entitlementsUnavailable
            case abilities
        }
    }
}
