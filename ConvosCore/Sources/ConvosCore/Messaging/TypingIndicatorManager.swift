import Foundation
import Observation

public struct TypingMember: Equatable, Sendable {
    public let inboxId: String
    public let startedAt: Date

    public init(inboxId: String, startedAt: Date = Date()) {
        self.inboxId = inboxId
        self.startedAt = startedAt
    }
}

@Observable
@MainActor
public final class TypingIndicatorManager {
    public static let shared: TypingIndicatorManager = .init()

    public var typingMembersByConversation: [String: [TypingMember]] = [:]

    private var expiryTasks: [String: [String: Task<Void, Never>]] = [:]

    private let expiryInterval: TimeInterval

    public static let defaultExpiryInterval: TimeInterval = 15

    public init(expiryInterval: TimeInterval = TypingIndicatorManager.defaultExpiryInterval) {
        self.expiryInterval = expiryInterval
    }

    public func typers(for conversationId: String) -> [TypingMember] {
        typingMembersByConversation[conversationId] ?? []
    }

    public func handleTypingEvent(
        conversationId: String,
        senderInboxId: String,
        isTyping: Bool
    ) {
        if isTyping {
            addTyper(conversationId: conversationId, inboxId: senderInboxId)
        } else {
            removeTyper(conversationId: conversationId, inboxId: senderInboxId)
        }
    }

    public func handleMessageReceived(conversationId: String, senderInboxId: String) {
        removeTyper(conversationId: conversationId, inboxId: senderInboxId)
    }

    public func clearAll(for conversationId: String) {
        typingMembersByConversation.removeValue(forKey: conversationId)
        cancelAllExpiryTasks(for: conversationId)
    }

    private func addTyper(conversationId: String, inboxId: String) {
        var members = typingMembersByConversation[conversationId] ?? []
        members.removeAll { $0.inboxId == inboxId }
        members.append(TypingMember(inboxId: inboxId))
        typingMembersByConversation[conversationId] = members

        scheduleExpiry(conversationId: conversationId, inboxId: inboxId)
    }

    private func removeTyper(conversationId: String, inboxId: String) {
        cancelExpiryTask(conversationId: conversationId, inboxId: inboxId)

        guard var members = typingMembersByConversation[conversationId] else { return }
        members.removeAll { $0.inboxId == inboxId }
        if members.isEmpty {
            typingMembersByConversation.removeValue(forKey: conversationId)
        } else {
            typingMembersByConversation[conversationId] = members
        }
    }

    private func scheduleExpiry(conversationId: String, inboxId: String) {
        cancelExpiryTask(conversationId: conversationId, inboxId: inboxId)

        let task = Task { [weak self, expiryInterval] in
            try? await Task.sleep(for: .seconds(expiryInterval))
            guard !Task.isCancelled else { return }
            self?.removeTyper(conversationId: conversationId, inboxId: inboxId)
        }

        if expiryTasks[conversationId] == nil {
            expiryTasks[conversationId] = [:]
        }
        expiryTasks[conversationId]?[inboxId] = task
    }

    private func cancelExpiryTask(conversationId: String, inboxId: String) {
        expiryTasks[conversationId]?[inboxId]?.cancel()
        expiryTasks[conversationId]?.removeValue(forKey: inboxId)
    }

    private func cancelAllExpiryTasks(for conversationId: String) {
        expiryTasks[conversationId]?.values.forEach { $0.cancel() }
        expiryTasks.removeValue(forKey: conversationId)
    }
}
