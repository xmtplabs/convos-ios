import Foundation

public extension ConvosAPI {
    /// Request body for `POST /v2/agent-templates/generations`. Phase 1 only
    /// sends text; the attachment array arrives in a later phase. `source`
    /// identifies the client flow and `clientDeviceId` backs PostHog
    /// attribution for anonymous/unauthenticated analytics.
    struct AgentTemplateGenerationRequest: Codable, Sendable {
        public struct Inputs: Codable, Sendable {
            public let text: String

            public init(text: String) {
                self.text = text
            }
        }

        public let source: String
        public let inputs: Inputs
        public let clientDeviceId: String?

        public init(source: String, inputs: Inputs, clientDeviceId: String?) {
            self.source = source
            self.inputs = inputs
            self.clientDeviceId = clientDeviceId
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

    /// In-progress draft identity shown while a build runs (PR #309). Identity
    /// only — `emoji`, not an avatar URL (the real photo arrives post-join).
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
    /// `nil`/empty when absent (e.g. before PR #309 is deployed). Extra keys
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
