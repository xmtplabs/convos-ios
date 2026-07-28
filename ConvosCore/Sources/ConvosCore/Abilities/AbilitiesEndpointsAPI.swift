import Foundation

/// Wire models and typed failures for the V2 abilities endpoints beyond the
/// catalog GET (which `AbilitiesAPI.CatalogResponse` covers):
///
/// - `POST /v2/abilities/{abilityId}/entitlement` -> `EntitlementInitiationResponse`
///   (docs/schemas/ability-entitlement-bind.schema.json)
/// - `POST /v2/abilities/{abilityId}/entitlement/complete` -> `EntitlementCompleteResponse`
///   (docs/schemas/ability-entitlement-complete.schema.json)
/// - `DELETE /v2/abilities/{abilityId}/entitlement` -> 204
/// - `GET /v2/conversations/{conversationId}/abilities` -> `ConversationAbilitiesResponse`
///   (docs/schemas/conversation-abilities.schema.json)
/// - `PUT /v2/conversations/{conversationId}/abilities/{abilityId}` -> `ConversationAbilityEntry`
/// - `DELETE /v2/conversations/{conversationId}/abilities/{abilityId}?agentInboxId=` -> 204
///
/// Error bodies are `{code, ...}`; the codes the client acts on are mapped to
/// `EndpointError` so callers can branch without string-matching HTTP bodies.
extension AbilitiesAPI {
    /// Typed failures surfaced by the abilities endpoints, mirroring the
    /// backend's error vocabulary. Codes the client does not act on
    /// specifically (e.g. `invalid_request`, `initiate_failed`) fall through
    /// to the generic `APIError` mapping.
    public enum EndpointError: Error, Sendable, Equatable {
        /// 409 `{code: auth_incomplete, status}` from entitlement complete:
        /// the owned connection is not ACTIVE yet (OAuth still finishing).
        /// The entitlement is untouched and stays `pending_auth`; retryable.
        case authIncomplete(connectionStatus: String?)
        /// 503 `{code: entitlements_unavailable}`: the entitlement tables
        /// are still converging after boot. Retryable.
        case entitlementsUnavailable
        /// 409 `{code: needs_entitlement}` from the conversation PUT: no
        /// active entitlement backs the extension.
        case needsEntitlement
        /// 404 `{code: unknown_ability}`: the ability id is not in the
        /// served catalog (hidden manifests included).
        case unknownAbility
        /// 400 `{code: unknown_bundle, bundleId}`: a stale bundle id. The
        /// staleness signal to refetch the catalog.
        case unknownBundle(bundleId: String?)
        /// 403 `{code: connection_not_owned}` from entitlement complete.
        case connectionNotOwned
        /// 409 `{code: ability_mismatch}` from entitlement complete: the
        /// connection belongs to a different toolkit.
        case abilityMismatch

        /// Maps a non-2xx response body to a typed error when it carries a
        /// code the client acts on; nil falls through to the generic
        /// `APIError` mapping.
        public init?(body: Data) {
            struct ErrorBody: Decodable {
                let code: String
                let status: String?
                let bundleId: String?
            }
            guard let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body) else {
                return nil
            }
            switch parsed.code {
            case "auth_incomplete":
                self = .authIncomplete(connectionStatus: parsed.status)
            case "entitlements_unavailable":
                self = .entitlementsUnavailable
            case "needs_entitlement":
                self = .needsEntitlement
            case "unknown_ability":
                self = .unknownAbility
            case "unknown_bundle":
                self = .unknownBundle(bundleId: parsed.bundleId)
            case "connection_not_owned":
                self = .connectionNotOwned
            case "ability_mismatch":
                self = .abilityMismatch
            default:
                return nil
            }
        }
    }

    /// `POST /v2/abilities/{abilityId}/entitlement` response. OAuth
    /// abilities answer `pending_auth` with the provider consent URL and the
    /// connection-request id to echo back to complete; auth-less abilities
    /// answer `active` with both auth fields null.
    public struct EntitlementInitiationResponse: Codable, Sendable, Hashable {
        public let status: EntitlementStatus
        public let redirectUrl: String?
        public let connectionRequestId: String?

        public init(status: EntitlementStatus, redirectUrl: String? = nil, connectionRequestId: String? = nil) {
            self.status = status
            self.redirectUrl = redirectUrl
            self.connectionRequestId = connectionRequestId
        }
    }

    /// `POST /v2/abilities/{abilityId}/entitlement/complete` response:
    /// always `active` on success.
    public struct EntitlementCompleteResponse: Codable, Sendable, Hashable {
        public let status: EntitlementStatus

        public init(status: EntitlementStatus) {
            self.status = status
        }
    }

    /// One (ability, agent) opt-in row from the conversation abilities
    /// endpoint. The extender appears as a conversation-visible inbox id
    /// only; the backing entitlement contributes only its status.
    public struct ConversationAbilityEntry: Codable, Sendable, Hashable {
        public let abilityId: String
        public let conversationId: String
        public let agentInboxId: String
        public let bundleIds: [String]
        /// Who extended it; null when a V2 write did not provide it.
        public let extendedByInboxId: String?
        /// True when the backing entitlement belongs to the caller -- the
        /// entries the caller may PUT/DELETE.
        public let extendedByMe: Bool
        public let status: EntitlementStatus
        public let createdAt: Date
        public let updatedAt: Date

        public init(
            abilityId: String,
            conversationId: String,
            agentInboxId: String,
            bundleIds: [String],
            extendedByInboxId: String?,
            extendedByMe: Bool,
            status: EntitlementStatus,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.abilityId = abilityId
            self.conversationId = conversationId
            self.agentInboxId = agentInboxId
            self.bundleIds = bundleIds
            self.extendedByInboxId = extendedByInboxId
            self.extendedByMe = extendedByMe
            self.status = status
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    /// `GET /v2/conversations/{conversationId}/abilities` response. Newest
    /// first, one entry per (ability, agent) opt-in across every member.
    public struct ConversationAbilitiesResponse: Codable, Sendable, Hashable {
        public let abilities: [ConversationAbilityEntry]

        public init(abilities: [ConversationAbilityEntry]) {
            self.abilities = abilities
        }
    }

    /// Decoder for abilities responses. Backend date-times are ISO8601 and
    /// may carry fractional seconds (JS `toISOString()`), which the stock
    /// `.iso8601` strategy rejects, so both shapes are accepted.
    public static func wireResponseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date-time: \(raw)"
            )
        }
        return decoder
    }
}

extension AbilitiesAPI.EndpointError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authIncomplete:
            "Still finishing sign-in. Try again in a moment."
        case .entitlementsUnavailable:
            "Abilities are updating. Try again in a moment."
        case .needsEntitlement:
            "Connect this ability before sharing it with a convo."
        case .unknownAbility:
            "This ability is no longer available."
        case .unknownBundle:
            "This permission is out of date. Refresh and try again."
        case .connectionNotOwned:
            "This sign-in belongs to a different account."
        case .abilityMismatch:
            "This sign-in doesn't match the ability being connected."
        }
    }
}
