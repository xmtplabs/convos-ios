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
        session.agentTemplateRepository().startGeneration(
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
        for _ in 0..<attempts {
            if case .ready(let result) = stateManager.currentState {
                return result.conversationId
            }
            try await Task.sleep(for: pollInterval)
        }
        throw FlowError.conversationNotReady
    }

    /// Polls the conversations repository until the new conversation's invite
    /// slug lands (the invite is written asynchronously after creation).
    public static func awaitInviteSlug(
        session: any SessionManagerProtocol,
        conversationId: String,
        attempts: Int = Constant.pollAttempts,
        pollInterval: Duration = Constant.pollInterval
    ) async throws -> String {
        for _ in 0..<attempts {
            let conversations = (try? session.conversationsRepository(for: [.allowed]).fetchAll()) ?? []
            if let slug = conversations.first(where: { $0.id == conversationId })?.invite?.urlSlug,
               !slug.isEmpty {
                return slug
            }
            try await Task.sleep(for: pollInterval)
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
