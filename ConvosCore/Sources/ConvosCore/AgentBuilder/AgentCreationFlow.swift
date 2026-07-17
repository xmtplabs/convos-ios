import Foundation

/// The shared commit recipe behind "Make". Every host that turns a prompt +
/// staged attachments into a building agent goes through this type: compress
/// the photos for the generation API, submit the generation, and persist the
/// creation-prompt card that renders the prompt + attachment thumbnails at
/// the top of the chat while the agent builds.
///
/// Hosts today are the in-app agent builder (`AgentBuilderViewModel`) and the
/// share extension's New Agent target. Keeping the recipe here is what keeps
/// them in lock step - a step added to one host used to silently go missing
/// from the other. Host-specific concerns stay with the caller: commit
/// animation, extension process runway, and how the prompt message is
/// delivered (the flow only allocates its client message id).
public enum AgentCreationFlow {
    /// One staged photo headed into the build.
    public struct Photo {
        public let id: UUID
        public let image: ImageType

        public init(id: UUID, image: ImageType) {
            self.id = id
            self.image = image
        }
    }

    /// Generation inputs and creation-card chips, built as a pair: a photo
    /// that fails compression is dropped from both, so the card never shows
    /// a thumbnail for an attachment that was never uploaded. Hosts may
    /// append further pairs (voice memo, connections) before committing.
    public struct PreparedAttachments: Sendable {
        public var inputs: [AgentBuildAttachmentInput]
        public var summaryAttachments: [AgentBuilderSummaryAttachment]
    }

    /// Everything the commit persists: the creation-prompt card plus the
    /// pre-allocated client message id for the prompt (nil for an
    /// attachment-only build). The caller sends the prompt under this id so
    /// the card bundles the sent message instead of showing a bare bubble.
    public struct Commit: Sendable {
        public let summary: AgentBuilderSummary
        public let promptMessageId: String?
    }

    public enum FlowError: Error {
        case conversationNotReady
        case inviteUnavailable
    }

    /// The conversation id and commit produced by `createAgent`. The prompt
    /// is not yet sent when this returns - callers clear any durable staging
    /// record first (the generation row now guarantees delivery), then call
    /// `sendPrompt(for:)`.
    public struct CreatedAgent: Sendable {
        public let conversationId: String
        public let commit: Commit
    }

    /// A hidden draft conversation created ahead of Make (see
    /// `prepareDraftConversation`), so the commit itself is instant.
    public struct PreparedConversation: Sendable {
        public let conversationId: String
        public let slug: String

        public init(conversationId: String, slug: String) {
            self.conversationId = conversationId
            self.slug = slug
        }
    }

    /// Creates the draft conversation in the background while the user is
    /// still composing, the way the in-app builder does - the row starts
    /// hidden (`startsUnused`) so a discarded draft leaves nothing visible,
    /// and `createAgent(preparedConversation:)` flips it visible at Make.
    /// The claim registration keeps the unused-conversation cache from
    /// handing the same row to another caller in this process.
    public static func prepareDraftConversation(
        session: any SessionManagerProtocol
    ) async throws -> PreparedConversation {
        let stateManager = session.messagingService().conversationStateManager()
        try await stateManager.createConversation(startsUnused: true)
        let conversationId = try await awaitReadyConversationId(stateManager: stateManager)
        await session.registerClaimedConversation(id: conversationId)
        let slug = try await awaitInviteSlug(session: session, conversationId: conversationId)
        return PreparedConversation(conversationId: conversationId, slug: slug)
    }

    /// Rebuilds attachments from staged JPEG bytes (the outbox drain path,
    /// where the original images no longer exist as in-memory `ImageType`s).
    /// The bytes go to the generation API as-is; card thumbnails are decoded
    /// from them.
    public static func prepareAttachments(storedPhotoJPEGs: [Data]) -> PreparedAttachments {
        var prepared = PreparedAttachments(inputs: [], summaryAttachments: [])
        for jpegData in storedPhotoJPEGs {
            guard let image = ImageType(data: jpegData) else {
                Log.error("AgentCreationFlow: staged photo bytes failed to decode; excluding from upload and summary")
                continue
            }
            prepared.inputs.append(AgentBuildAttachmentInput(data: jpegData, mimeType: "image/jpeg", filename: nil))
            prepared.summaryAttachments.append(.photo(id: UUID(), thumbnailData: thumbnailData(for: image)))
        }
        return prepared
    }

    /// The complete new-conversation Make: create the conversation, wait for
    /// ready + invite slug, submit the generation, and persist the creation
    /// card. Used by hosts without an existing draft conversation (the share
    /// extension and the staged-build drain); the in-app builder owns its own
    /// conversation lifecycle and calls `makeCommit`/`start` directly.
    public static func createAgent(
        prompt: String,
        prepared: PreparedAttachments,
        session: any SessionManagerProtocol,
        preparedConversation: PreparedConversation? = nil
    ) async throws -> CreatedAgent {
        let conversationId: String
        let slug: String
        if let preparedConversation {
            conversationId = preparedConversation.conversationId
            slug = preparedConversation.slug
            // The pre-created row is hidden; Make is the moment it becomes a
            // real, visible conversation.
            await session.commitClaimedConversation(id: conversationId)
        } else {
            let stateManager = session.messagingService().conversationStateManager()
            try await stateManager.createConversation(startsUnused: false)
            conversationId = try await awaitReadyConversationId(stateManager: stateManager)
            slug = try await awaitInviteSlug(session: session, conversationId: conversationId)
        }
        let commit = makeCommit(prompt: prompt, attachments: prepared.summaryAttachments)
        await start(commit, inputs: prepared.inputs, session: session, conversationId: conversationId, slug: slug)
        return CreatedAgent(conversationId: conversationId, commit: commit)
    }

    /// Publishes the prompt as a builder-bundle send under the commit's
    /// pre-allocated message id: the bundle path records the id as hidden,
    /// so every client renders the prompt inside the creation card instead
    /// of as a separate bubble - a plain text send here shows up as a
    /// normal message next to the card. Returns the writer (nil for an
    /// attachment-only build) so extension hosts can hold a publish runway
    /// on it.
    @discardableResult
    public static func sendPrompt(
        for created: CreatedAgent,
        session: any SessionManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol
    ) async throws -> (any OutgoingMessageWriterProtocol)? {
        guard let promptMessageId = created.commit.promptMessageId else { return nil }
        let writer = session.messagingService().messageWriter(
            for: created.conversationId,
            backgroundUploadManager: backgroundUploadManager
        )
        try await writer.sendBuilderBundle(
            text: created.commit.summary.prompt,
            bundleItems: [],
            textClientMessageId: promptMessageId,
            bundleClientMessageId: UUID().uuidString,
            awaitsAgentJoin: false
        )
        return writer
    }

    /// Compresses photos for the generation API and builds the matching
    /// creation-card chips.
    public static func prepareAttachments(photos: [Photo]) -> PreparedAttachments {
        var prepared = PreparedAttachments(inputs: [], summaryAttachments: [])
        for photo in photos {
            guard let data = ImageCompression.compressForPhotoAttachment(photo.image) else {
                Log.error("AgentCreationFlow: failed to compress photo \(photo.id); excluding from upload and summary")
                continue
            }
            prepared.inputs.append(AgentBuildAttachmentInput(data: data, mimeType: "image/jpeg", filename: nil))
            prepared.summaryAttachments.append(.photo(id: photo.id, thumbnailData: thumbnailData(for: photo.image)))
        }
        return prepared
    }

    /// Small JPEG thumbnail for a creation-card chip, kept well under the
    /// full upload size so the persisted summary row stays light.
    public static func thumbnailData(for image: ImageType) -> Data? {
        ImageCompression.shared.resizeAndCompressToJPEG(
            image,
            maxSize: CGSize(width: Constant.thumbnailMaxDimension, height: Constant.thumbnailMaxDimension),
            compressionQuality: Constant.thumbnailQuality
        )
    }

    /// Builds the creation-prompt card and allocates the prompt's client
    /// message id. Synchronous so hosts can hand the summary to an on-screen
    /// view model before the async submission starts.
    public static func makeCommit(
        prompt: String,
        attachments: [AgentBuilderSummaryAttachment],
        cloudConnectionIds: [String: String] = [:],
        extraBundledMessageIds: Set<String> = [],
        existingConversation: Bool = false
    ) -> Commit {
        let promptMessageId: String? = prompt.isEmpty ? nil : UUID().uuidString
        var bundledIds = extraBundledMessageIds
        if let promptMessageId {
            bundledIds.insert(promptMessageId)
        }
        let summary = AgentBuilderSummary(
            prompt: prompt,
            attachments: attachments,
            cutoffDate: Date(),
            bundledMessageIds: bundledIds,
            cloudConnectionIds: cloudConnectionIds,
            existingConversation: existingConversation
        )
        return Commit(summary: summary, promptMessageId: promptMessageId)
    }

    /// Submits the generation and persists the creation-prompt card. A card
    /// persist failure is logged, not thrown: the generation is already
    /// running and delivery does not depend on the card.
    public static func start(
        _ commit: Commit,
        inputs: [AgentBuildAttachmentInput],
        session: any SessionManagerProtocol,
        conversationId: String,
        slug: String,
        connections: [String] = [],
        variantId: String? = nil
    ) async {
        await session.agentTemplateRepository().startGeneration(
            prompt: commit.summary.prompt,
            conversationId: conversationId,
            slug: slug,
            attachments: inputs,
            connections: connections,
            variantId: variantId
        )
        do {
            try await session.agentBuilderSummaryWriter().save(commit.summary, for: conversationId)
        } catch {
            Log.error("AgentCreationFlow: failed to persist creation prompt summary: \(error.localizedDescription)")
        }
    }

    /// Polls the state machine until conversation creation reaches `.ready`.
    /// For hosts (like the share extension) that create the conversation
    /// themselves; the in-app builder's draft lifecycle owns its own wait.
    public static func awaitReadyConversationId(
        stateManager: any ConversationStateManagerProtocol,
        attempts: Int = Constant.pollAttempts,
        pollInterval: Duration = Constant.pollInterval
    ) async throws -> String {
        for attempt in 0..<attempts {
            if case .ready(let result) = stateManager.currentState {
                return result.conversationId
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: pollInterval)
            }
        }
        throw FlowError.conversationNotReady
    }

    /// Polls the conversation row until its invite slug lands (the invite is
    /// written asynchronously after creation). Uses the single-conversation
    /// repository, which - unlike the list repository - also resolves rows
    /// still hidden behind `startsUnused`.
    public static func awaitInviteSlug(
        session: any SessionManagerProtocol,
        conversationId: String,
        attempts: Int = Constant.pollAttempts,
        pollInterval: Duration = Constant.pollInterval
    ) async throws -> String {
        let repository = session.conversationRepository(for: conversationId)
        for attempt in 0..<attempts {
            if let slug = (try? repository.fetchConversation())?.invite?.urlSlug,
               !slug.isEmpty {
                return slug
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: pollInterval)
            }
        }
        throw FlowError.inviteUnavailable
    }

    public enum Constant {
        public static let pollAttempts: Int = 50
        public static let pollInterval: Duration = .milliseconds(200)
        static let thumbnailMaxDimension: CGFloat = 240
        static let thumbnailQuality: CGFloat = 0.7
    }
}
