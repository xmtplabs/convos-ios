import Foundation
import GRDB

public struct SeedConversationResult: Sendable {
    public let index: Int
    public let conversationId: String
    public let name: String
    public let inviteURL: String
}

extension SessionManager {
    public func seedConversations(
        count: Int,
        domain: String,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [SeedConversationResult] {
        var results: [SeedConversationResult] = []

        QAEvent.emit(.app, "seed_started", ["count": "\(count)"])

        for i in 1...count {
            let name = "Seed \(i)"

            let (service, existingConversationId) = await addInbox()

            let stateManager: any ConversationStateManagerProtocol
            if let existingConversationId {
                stateManager = service.conversationStateManager(for: existingConversationId)
            } else {
                stateManager = service.conversationStateManager()
                try await stateManager.createConversation()
            }

            let conversationId = stateManager.draftConversationRepository.conversationId

            try await stateManager.conversationMetadataWriter.updateName(name, for: conversationId)
            try await stateManager.send(text: "Seed message \(i)")

            let invite = try await waitForInvite(conversationId: conversationId)
            let inviteURL = "https://\(domain)/v2?i=\(invite.urlSlug)"

            let result = SeedConversationResult(
                index: i,
                conversationId: conversationId,
                name: name,
                inviteURL: inviteURL
            )
            results.append(result)

            QAEvent.emit(.app, "seed_conversation", [
                "index": "\(i)",
                "id": conversationId,
                "name": name,
                "invite_url": inviteURL,
            ])

            progress?(i)
        }

        QAEvent.emit(.app, "seed_completed", ["count": "\(count)"])
        return results
    }

    private func waitForInvite(conversationId: String, timeout: TimeInterval = 10) async throws -> Invite {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let invite = try? await databaseReader.read({ db in
                try DBInvite
                    .filter(DBInvite.Columns.conversationId == conversationId)
                    .fetchOne(db)?
                    .hydrateInvite()
            }), !invite.urlSlug.isEmpty {
                return invite
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        throw SeedError.inviteNotGenerated(conversationId: conversationId)
    }

    enum SeedError: Error, LocalizedError {
        case inviteNotGenerated(conversationId: String)

        var errorDescription: String? {
            switch self {
            case .inviteNotGenerated(let id):
                return "Invite was not generated for conversation \(id) within timeout"
            }
        }
    }
}
