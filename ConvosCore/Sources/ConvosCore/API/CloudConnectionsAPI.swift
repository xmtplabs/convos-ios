import Foundation

public enum CloudConnectionsAPI {
    public struct InitiateResponse: Codable, Sendable {
        public let connectionRequestId: String
        public let redirectUrl: String
    }

    public struct CompleteResponse: Codable, Sendable {
        public let connectionId: String
        public let serviceId: String
        public let serviceName: String
        public let composioEntityId: String
        public let composioConnectionId: String
        public let status: String
    }

    public struct ConnectionResponse: Codable, Sendable {
        public let connectionId: String
        public let serviceId: String
        public let serviceName: String
        public let composioEntityId: String
        public let composioConnectionId: String
        public let status: String
    }

    public struct ListResponse: Codable, Sendable {
        public let connections: [ConnectionResponse]
    }

    public struct CreateGrantResponse: Codable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }
    }

    /// Typed failure surfaced by `createConnectionGrant` when the backend
    /// rejects a bundle id that isn't in its catalog for the toolkit
    /// (HTTP 400 `{"code": "unknown_bundle", "bundleId": "<the bad id>"}`).
    /// This is the staleness signal on the HTTP path: callers refetch
    /// `GET /v2/connections/services`, drop unknown ids, and retry once.
    public enum GrantError: Error, Sendable, Equatable {
        case unknownBundle(bundleId: String?)
    }

    // MARK: - Services catalog (GET /v2/connections/services)

    /// A localized string map from the services catalog. Always carries an
    /// `"en"` key (the guaranteed fallback); may carry more locales.
    public struct LocalizedString: Codable, Sendable, Hashable {
        public let values: [String: String]

        public init(values: [String: String]) {
            self.values = values
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.values = try container.decode([String: String].self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }

        /// Renders for `locale` with the plan's fallback chain:
        /// `map[locale.languageCode] ?? map["en"] ?? ""`.
        public func resolved(for locale: Locale = .current) -> String {
            if let code = locale.language.languageCode?.identifier, let value = values[code] {
                return value
            }
            return values["en"] ?? ""
        }
    }

    /// One permission bundle row in the picker: a stable id the grant
    /// persists, plus the localized copy and the toggle's initial state.
    public struct ServiceBundle: Codable, Sendable, Hashable {
        public let id: String
        public let title: LocalizedString
        public let description: LocalizedString
        public let defaultEnabled: Bool

        public init(id: String, title: LocalizedString, description: LocalizedString, defaultEnabled: Bool) {
            self.id = id
            self.title = title
            self.description = description
            self.defaultEnabled = defaultEnabled
        }
    }

    /// Optional service icon. Omitted by the backend in v1.
    public struct ServiceIcon: Codable, Sendable, Hashable {
        public let format: String
        public let base64: String

        public init(format: String, base64: String) {
            self.format = format
            self.base64 = base64
        }
    }

    /// One backend-owned service in the connections-picker catalog. `id`
    /// equals the Composio toolkit slug and is sent back as `toolkit` on a
    /// grant. `version` bumps whenever anything about the service changes;
    /// clients refetch on a mismatch (stale detection). Composio action slugs
    /// are deliberately absent: the backend alone resolves bundle → actions.
    public struct ServiceConfig: Codable, Sendable, Hashable {
        public let id: String
        public let composioSlug: String
        public let version: Int
        public let displayName: LocalizedString
        public let icon: ServiceIcon?
        public let bundles: [ServiceBundle]

        public init(
            id: String,
            composioSlug: String,
            version: Int,
            displayName: LocalizedString,
            icon: ServiceIcon? = nil,
            bundles: [ServiceBundle]
        ) {
            self.id = id
            self.composioSlug = composioSlug
            self.version = version
            self.displayName = displayName
            self.icon = icon
            self.bundles = bundles
        }
    }

    public struct ServicesResponse: Codable, Sendable {
        public let services: [ServiceConfig]

        public init(services: [ServiceConfig]) {
            self.services = services
        }
    }

    public struct RevokeGrantResponse: Codable, Sendable {
        public let revoked: Int

        public init(revoked: Int) {
            self.revoked = revoked
        }
    }
}
