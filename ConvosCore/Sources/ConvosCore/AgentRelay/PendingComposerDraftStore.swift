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

public final class PendingComposerDraftStore: PendingComposerDraftStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(environment: AppEnvironment) {
        defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
    }

    public func stage(_ draft: PendingComposerDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Constant.draftKey)
    }

    public func take(for conversationId: String) -> PendingComposerDraft? {
        guard let data = defaults.data(forKey: Constant.draftKey),
              let draft = try? JSONDecoder().decode(PendingComposerDraft.self, from: data) else {
            defaults.removeObject(forKey: Constant.draftKey)
            return nil
        }
        guard draft.conversationId == conversationId else { return nil }

        defaults.removeObject(forKey: Constant.draftKey)
        guard Date().timeIntervalSince(draft.stagedAt) < Constant.maximumAge else { return nil }
        return draft
    }

    func clear() {
        defaults.removeObject(forKey: Constant.draftKey)
    }

    private enum Constant {
        static let draftKey: String = "agentRelay.pendingComposerDraft"
        static let maximumAge: TimeInterval = 600
    }
}
