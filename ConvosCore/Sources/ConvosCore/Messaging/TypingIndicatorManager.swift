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

/// Closure that schedules `action` to run after `delay` seconds and returns
/// a cancel handle. The default implementation wraps `Task.sleep`; tests
/// inject one that captures the action so expiry can fire deterministically
/// without wall-clock waits.
public typealias TypingExpiryScheduler = @MainActor (
    _ delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> @MainActor () -> Void

@Observable
@MainActor
public final class TypingIndicatorManager {
    public static let shared: TypingIndicatorManager = .init()

    public var typingMembersByConversation: [String: [TypingMember]] = [:]

    private var expiryCancels: [String: [String: @MainActor () -> Void]] = [:]

    private let expiryInterval: TimeInterval
    private let scheduleExpiryAction: TypingExpiryScheduler

    public static let defaultExpiryInterval: TimeInterval = 15

    public init(
        expiryInterval: TimeInterval = TypingIndicatorManager.defaultExpiryInterval,
        scheduler: TypingExpiryScheduler? = nil
    ) {
        self.expiryInterval = expiryInterval
        self.scheduleExpiryAction = scheduler ?? Self.taskBasedScheduler
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

        let cancel = scheduleExpiryAction(expiryInterval) { [weak self] in
            self?.removeTyper(conversationId: conversationId, inboxId: inboxId)
        }

        if expiryCancels[conversationId] == nil {
            expiryCancels[conversationId] = [:]
        }
        expiryCancels[conversationId]?[inboxId] = cancel
    }

    private func cancelExpiryTask(conversationId: String, inboxId: String) {
        if let cancel = expiryCancels[conversationId]?[inboxId] {
            cancel()
        }
        expiryCancels[conversationId]?.removeValue(forKey: inboxId)
    }

    private func cancelAllExpiryTasks(for conversationId: String) {
        expiryCancels[conversationId]?.values.forEach { $0() }
        expiryCancels.removeValue(forKey: conversationId)
    }

    private static let taskBasedScheduler: TypingExpiryScheduler = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}
