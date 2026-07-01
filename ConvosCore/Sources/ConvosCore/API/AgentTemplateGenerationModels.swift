import Foundation

public extension ConvosAPI {
    /// A binary input already uploaded via the agent-templates presigned
    /// endpoint, referenced by its opaque `objectKey`. The bytes live in a
    /// private bucket the backend reads itself — there is no public URL and no
    /// XMTP attachment crypto in this path. `mimeType` must be in the backend
    /// allowlist (image/png, image/jpeg, application/pdf, and the audio set).
    struct AttachmentRef: Codable, Sendable, Equatable {
        public let objectKey: String
        public let mimeType: String
        public let filename: String?

        public init(objectKey: String, mimeType: String, filename: String? = nil) {
            self.objectKey = objectKey
            self.mimeType = mimeType
            self.filename = filename
        }
    }

    /// Request body for `POST /v2/agent-templates/generations`. Carries text
    /// and/or `attachments` (object-key references uploaded ahead of time).
    /// `source` identifies the client flow and `clientDeviceId` backs PostHog
    /// attribution for anonymous/unauthenticated analytics.
    struct AgentTemplateGenerationRequest: Codable, Sendable {
        public struct Inputs: Codable, Sendable {
            public let text: String
            /// Omitted from the encoded body when empty so text-only requests
            /// stay byte-identical to the attachment-free shape.
            public let attachments: [AttachmentRef]?

            public init(text: String, attachments: [AttachmentRef]? = nil) {
                self.text = text
                self.attachments = attachments
            }
        }

        public let source: String
        public let inputs: Inputs
        /// Neutral service ids the agent should use (e.g. `["googlecalendar"]`).
        /// Awareness only -- the generated prompt/welcome lean on the capability
        /// and `template.connections` records it; no grant is issued here.
        /// Omitted from the encoded body when empty so connectionless builds stay
        /// byte-identical and dedupe against a stored `[]`.
        public let connections: [String]?
        public let clientDeviceId: String?
        /// Publish visibility for the generated template, a top-level envelope
        /// field alongside `source`. The app submits `"unlisted"` (templates
        /// built in-app are private to the build flow, not surfaced in any public
        /// directory), matching the website create flow. Always encoded; when the
        /// field is absent the backend defaults to a listed/public template.
        public let publishStatus: String
        /// Dev-only agent variant slug. A top-level envelope field (sibling of
        /// `source`/`inputs`, not nested in `inputs`) selecting the variant's
        /// builder prompt server-side. Omitted from the encoded body when `nil`
        /// (via `encodeIfPresent`) so default builds stay byte-identical; the
        /// backend schema is `.strict()`, so the key only belongs at top level.
        public let variantId: String?

        public init(source: String, inputs: Inputs, connections: [String]? = nil, clientDeviceId: String?, publishStatus: String, variantId: String? = nil) {
            self.source = source
            self.inputs = inputs
            self.connections = connections
            self.clientDeviceId = clientDeviceId
            self.publishStatus = publishStatus
            self.variantId = variantId
        }
    }

    /// Server-side generation lifecycle. `pending` and `running` are
    /// non-terminal; `done` carries a `templateId`; `failed` carries an
    /// `error`. Unknown values decode to `.unknown` so a new backend status
    /// never crashes the client.
    enum AgentGenerationStatus: String, Codable, Sendable {
        case pending
        case running
        case done
        case failed
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = AgentGenerationStatus(rawValue: raw) ?? .unknown
        }

        public var isTerminal: Bool {
            self == .done || self == .failed
        }
    }

    /// In-progress draft identity shown while a build runs. Identity only —
    /// `emoji`, not an avatar URL (the real photo arrives post-join).
    struct AgentPreview: Codable, Sendable, Equatable {
        public let agentName: String?
        public let emoji: String?
        public let description: String?

        public init(agentName: String?, emoji: String?, description: String?) {
            self.agentName = agentName
            self.emoji = emoji
            self.description = description
        }
    }

    /// Response from both the submit (`POST`) and poll (`GET`) endpoints.
    /// `preview` + `progressPhrases` ride only the in-progress (`202`)
    /// responses and are absent on the terminal (`200`); both decode to
    /// `nil`/empty when absent (e.g. before the backend emits them). Extra keys
    /// (`reply`, `createdAt`, `updatedAt`) are ignored by the default decoder.
    struct AgentTemplateGenerationResponse: Codable, Sendable {
        public let generationId: String
        public let status: AgentGenerationStatus
        public let templateId: String?
        public let error: String?
        public let preview: AgentPreview?
        public let progressPhrases: [String]?

        public init(
            generationId: String,
            status: AgentGenerationStatus,
            templateId: String?,
            error: String?,
            preview: AgentPreview? = nil,
            progressPhrases: [String]? = nil
        ) {
            self.generationId = generationId
            self.status = status
            self.templateId = templateId
            self.error = error
            self.preview = preview
            self.progressPhrases = progressPhrases
        }
    }
}

/// Typed failures for the agent-template generation endpoints. Kept separate
/// from `APIError` so the repository can branch precisely (e.g. moderation is
/// terminal and user-facing, a 5xx is retryable) without widening `APIError`'s
/// exhaustive switches.
public enum AgentGenerationError: Error, Sendable {
    /// 422 — content moderation rejected the prompt. Terminal; surface to the
    /// user as "we can't build that".
    case moderationBlocked(String?)
    /// 409 — idempotency key reused with a different body. A client logic bug.
    case conflict
    /// 400 — malformed body.
    case badRequest(String?)
    /// 413 — body too large.
    case payloadTooLarge
    /// 404 — generation expired or never existed (poll path).
    case notFound
    /// 5xx / transport failure. Retryable.
    case server(String?)
}
