import Foundation

public extension ConvosAPI {
    /// A registered dev-only agent variant from the backend registry
    /// (`GET /v2/agent-variants`). A named bundle pinning an ephemeral runtime
    /// (`assistantWorkerUrl`, Axis A) and/or a builder prompt
    /// (`builderPromptSlug`, Axis B); the app selects one by `slug` and carries
    /// that slug through the generation, join, and join-status-poll calls.
    struct AgentVariant: Codable, Sendable, Equatable, Identifiable {
        public let slug: String
        public let label: String
        public let whatToTest: String
        /// Registry lifecycle, e.g. `building` | `ready`. Kept a string (not an
        /// enum) so an unknown backend status never fails decoding.
        public let status: String
        /// Ephemeral worker host (Axis A); `nil` for a default-runtime variant.
        public let assistantWorkerUrl: String?
        /// Bench/Braintrust builder-prompt slug (Axis B); `nil` for the canonical
        /// generator prompt.
        public let builderPromptSlug: String?
        public let prUrl: String?
        public let branch: String?
        public let commit: String?

        public var id: String { slug }

        public init(
            slug: String,
            label: String,
            whatToTest: String,
            status: String,
            assistantWorkerUrl: String? = nil,
            builderPromptSlug: String? = nil,
            prUrl: String? = nil,
            branch: String? = nil,
            commit: String? = nil
        ) {
            self.slug = slug
            self.label = label
            self.whatToTest = whatToTest
            self.status = status
            self.assistantWorkerUrl = assistantWorkerUrl
            self.builderPromptSlug = builderPromptSlug
            self.prUrl = prUrl
            self.branch = branch
            self.commit = commit
        }
    }

    /// Envelope for `GET /v2/agent-variants` -- the registry returns
    /// `{ data: [ ... ] }`, not a bare array.
    struct AgentVariantsResponse: Codable, Sendable {
        public let data: [AgentVariant]

        public init(data: [AgentVariant]) {
            self.data = data
        }
    }
}

public extension ConvosAPI.AgentVariant {
    /// The profile-stamp projection of this registry variant, so the pre-Make
    /// selector can preview a chosen variant with the same `AgentVariantStamp`-
    /// driven views the built agent shows.
    var stamp: AgentVariantStamp {
        AgentVariantStamp(slug: slug, label: label, whatToTest: whatToTest, prUrl: prUrl)
    }
}

/// The variant marker stamped onto a variant-built agent's XMTP profile
/// (`Profile.metadata["variant"]`), written by the assistants worker at join as
/// `JSON.stringify({ slug, label, whatToTest, prUrl })`. Read by the dev variant
/// ribbon, profile card, and name/header badges. A smaller, distinct shape from
/// the registry `ConvosAPI.AgentVariant`: only these four fields ride the profile.
public struct AgentVariantStamp: Codable, Sendable, Equatable, Hashable {
    public let slug: String
    public let label: String
    public let whatToTest: String
    public let prUrl: String?

    public init(slug: String, label: String, whatToTest: String, prUrl: String? = nil) {
        self.slug = slug
        self.label = label
        self.whatToTest = whatToTest
        self.prUrl = prUrl
    }
}
