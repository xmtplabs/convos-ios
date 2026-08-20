import Foundation

/// Text staged for a conversation's composer by the copy-to-convo flow.
/// Drained by the conversation view model when it opens the matching
/// conversation; entries older than ten minutes are ignored.
public struct PendingComposerDraft: Codable, Equatable, Sendable {
    public let conversationId: String
    public let text: String
    public let stagedAt: Date

    public init(conversationId: String, text: String, stagedAt: Date) {
        self.conversationId = conversationId
        self.text = text
        self.stagedAt = stagedAt
    }
}

public protocol PendingComposerDraftStoring: Sendable {
    func stage(_ draft: PendingComposerDraft)
    func take(for conversationId: String) -> PendingComposerDraft?
}

public final class PendingComposerDraftStore: PendingComposerDraftStoring {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func stage(_ draft: PendingComposerDraft) {}

    public func take(for conversationId: String) -> PendingComposerDraft? {
        nil
    }
}
