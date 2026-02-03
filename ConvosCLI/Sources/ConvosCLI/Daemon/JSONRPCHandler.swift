import Combine
import ConvosCore
import Foundation

/// Handles JSON-RPC method dispatch and execution
actor JSONRPCHandler {
    private let context: CLIContext

    init(context: CLIContext) {
        self.context = context
    }

    /// Handle a JSON-RPC request and return a response
    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        // Validate request
        if let error = request.validate() {
            return JSONRPCResponse(error: error.object, id: request.id)
        }

        do {
            let result = try await dispatch(request)
            return JSONRPCResponse(result: result, id: request.id)
        } catch let error as JSONRPCError {
            return JSONRPCResponse(error: error.object, id: request.id)
        } catch {
            return JSONRPCResponse(
                error: JSONRPCError.internalError(error.localizedDescription).object,
                id: request.id
            )
        }
    }

    /// Dispatch request to appropriate method handler
    private func dispatch(_ request: JSONRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "conversations.list":
            return try await listConversations(request.params)
        case "conversations.create":
            return try await createConversation(request.params)
        case "conversations.join":
            return try await joinConversation(request.params)
        case "conversations.invite":
            return try await getInvite(request.params)
        case "messages.list":
            return try await listMessages(request.params)
        case "messages.send":
            return try await sendMessage(request.params)
        case "messages.react":
            return try await react(request.params)
        case "account.info":
            return try await getAccountInfo()
        default:
            throw JSONRPCError.methodNotFound(request.method)
        }
    }

    // MARK: - Method Implementations

    private func listConversations(_ params: [String: JSONValue]?) async throws -> JSONValue {
        let limit = params?["limit"]?.intValue
        let includeHidden = params?["includeHidden"]?.boolValue ?? false

        let consent: [Consent] = includeHidden ? .all : [.allowed, .unknown]
        let repo = context.session.conversationsRepository(for: consent)
        var conversations = try repo.fetchAll()

        if let limit = limit {
            conversations = Array(conversations.prefix(limit))
        }

        let output = conversations.map { conv in
            ConversationInfo(
                id: conv.id,
                displayName: conv.displayName,
                memberCount: conv.members.count,
                isUnread: conv.isUnread,
                isPinned: conv.isPinned,
                isMuted: conv.isMuted,
                kind: conv.kind.rawValue,
                createdAt: conv.createdAt,
                lastMessagePreview: conv.lastMessage?.text
            )
        }

        return try JSONValue.from(output)
    }

    private func createConversation(_ params: [String: JSONValue]?) async throws -> JSONValue {
        let name = params?["name"]?.stringValue

        // Create a new inbox for this conversation
        // Note: createConversation() internally waits for inbox ready
        let messagingService = await context.session.addInbox()
        let stateManager = messagingService.conversationStateManager()

        // Wait for conversation to be ready (which triggers createConversation internally)
        let result = try await waitForConversationReady(stateManager: stateManager)

        // Update conversation metadata if name provided
        if let name = name {
            try await stateManager.conversationMetadataWriter.updateName(name, for: result.conversationId)
        }

        // Get the invite from the session's invite repository
        let inviteRepo = context.session.inviteRepository(for: result.conversationId)
        let inviteSlug = try await waitForInvite(inviteRepo: inviteRepo)

        let output = CreateConversationResult(
            conversationId: result.conversationId,
            inviteSlug: inviteSlug
        )

        return try JSONValue.from(output)
    }

    private func joinConversation(_ params: [String: JSONValue]?) async throws -> JSONValue {
        guard let invite = params?["invite"]?.stringValue else {
            throw JSONRPCError.invalidParams("invite is required")
        }

        let noWait = params?["noWait"]?.boolValue ?? false

        // Extract slug from URL if needed
        let inviteSlug = extractInviteSlug(from: invite)

        // Create a new inbox for joining
        // Note: joinConversation() internally waits for inbox ready
        let messagingService = await context.session.addInbox()
        let stateManager = messagingService.conversationStateManager()

        if noWait {
            // Just validate and start the join
            try await stateManager.joinConversation(inviteCode: inviteSlug)

            let output = JoinResult(
                status: "waiting_for_acceptance",
                conversationId: nil
            )
            return try JSONValue.from(output)
        } else {
            // Wait for full acceptance
            let result = try await waitForJoinReady(stateManager: stateManager, inviteCode: inviteSlug)

            let output = JoinResult(
                status: "joined",
                conversationId: result.conversationId
            )
            return try JSONValue.from(output)
        }
    }

    private func getInvite(_ params: [String: JSONValue]?) async throws -> JSONValue {
        guard let conversationId = params?["conversationId"]?.stringValue else {
            throw JSONRPCError.invalidParams("conversationId is required")
        }

        // Find the conversation to get clientId and inboxId
        let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
        let conversations = try repo.fetchAll()
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw JSONRPCError.invalidParams("Conversation not found: \(conversationId)")
        }

        // Wake the messaging service to ensure invite is available
        _ = try await context.session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )

        // Get invite from session's invite repository
        let inviteRepo = context.session.inviteRepository(for: conversationId)
        let inviteSlug = try await waitForInvite(inviteRepo: inviteRepo)

        let output = InviteResult(inviteSlug: inviteSlug)
        return try JSONValue.from(output)
    }

    private func listMessages(_ params: [String: JSONValue]?) async throws -> JSONValue {
        guard let conversationId = params?["conversationId"]?.stringValue else {
            throw JSONRPCError.invalidParams("conversationId is required")
        }

        let limit = params?["limit"]?.intValue ?? 50

        let messagesRepo = context.session.messagesRepository(for: conversationId)
        let messages = try messagesRepo.fetchInitial()

        let output = messages.prefix(limit).map { message in
            MessageInfo(
                id: message.id,
                conversationId: conversationId,
                senderId: message.base.sender.profile.id,
                senderName: message.base.sender.profile.displayName ?? "Unknown",
                content: messageContent(message),
                timestamp: message.base.date
            )
        }

        return try JSONValue.from(Array(output))
    }

    private func sendMessage(_ params: [String: JSONValue]?) async throws -> JSONValue {
        guard let conversationId = params?["conversationId"]?.stringValue else {
            throw JSONRPCError.invalidParams("conversationId is required")
        }
        guard let message = params?["message"]?.stringValue else {
            throw JSONRPCError.invalidParams("message is required")
        }

        // Find the conversation to get clientId and inboxId
        let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
        let conversations = try repo.fetchAll()
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw JSONRPCError.invalidParams("Conversation not found: \(conversationId)")
        }

        // Get the messaging service for this conversation
        let messagingService = try await context.session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )

        // Send the message using the message writer
        let messageWriter = messagingService.messageWriter(for: conversationId)
        try await messageWriter.send(text: message)

        let output = SendResult(success: true)
        return try JSONValue.from(output)
    }

    private func react(_ params: [String: JSONValue]?) async throws -> JSONValue {
        guard let conversationId = params?["conversationId"]?.stringValue else {
            throw JSONRPCError.invalidParams("conversationId is required")
        }
        guard let messageId = params?["messageId"]?.stringValue else {
            throw JSONRPCError.invalidParams("messageId is required")
        }
        guard let emoji = params?["emoji"]?.stringValue else {
            throw JSONRPCError.invalidParams("emoji is required")
        }

        let remove = params?["remove"]?.boolValue ?? false

        // Find the conversation to get clientId and inboxId
        let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
        let conversations = try repo.fetchAll()
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw JSONRPCError.invalidParams("Conversation not found: \(conversationId)")
        }

        // Get the messaging service for this conversation
        let messagingService = try await context.session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )

        let reactionWriter = messagingService.reactionWriter()

        if remove {
            try await reactionWriter.removeReaction(emoji: emoji, from: messageId, in: conversationId)
        } else {
            try await reactionWriter.addReaction(emoji: emoji, to: messageId, in: conversationId)
        }

        let output = ReactResult(success: true, action: remove ? "removed" : "added")
        return try JSONValue.from(output)
    }

    private func getAccountInfo() async throws -> JSONValue {
        // Return information about the current inbox state
        let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
        let conversations = try repo.fetchAll()

        let output = AccountInfo(
            conversationCount: conversations.count,
            environment: "dev" // Could get from context if needed
        )

        return try JSONValue.from(output)
    }

    // MARK: - Helpers

    private func extractInviteSlug(from invite: String) -> String {
        if let url = URL(string: invite),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let slugItem = queryItems.first(where: { $0.name == "i" }),
           let slug = slugItem.value {
            return slug
        }
        return invite
    }

    private func messageContent(_ message: AnyMessage) -> String {
        switch message.base.content {
        case .text(let text):
            return text
        case .emoji(let emoji):
            return emoji
        case .invite:
            return "[Invite]"
        case .attachment:
            return "[Attachment]"
        case .attachments(let urls):
            return "[Attachments: \(urls.count)]"
        case .update:
            return "[Group updated]"
        }
    }

    private func waitForConversationReady(stateManager: any ConversationStateManagerProtocol) async throws -> ConversationReadyResult {
        // Trigger conversation creation
        try await stateManager.createConversation()

        // Poll for state changes since CLI doesn't have a RunLoop for MainActor callbacks
        while true {
            try Task.checkCancellation()

            let state = stateManager.currentState

            switch state {
            case .ready(let result):
                return result

            case .error(let error):
                throw error

            default:
                // Wait a bit before checking again
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private func waitForInvite(inviteRepo: any InviteRepositoryProtocol) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var hasResumed = false

            cancellable = inviteRepo.invitePublisher
                .compactMap { $0 }
                .first()
                .sink(
                    receiveCompletion: { completion in
                        guard !hasResumed else { return }
                        if case .failure(let error) = completion {
                            hasResumed = true
                            continuation.resume(throwing: error)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { invite in
                        guard !hasResumed else { return }
                        hasResumed = true
                        continuation.resume(returning: invite.urlSlug)
                        cancellable?.cancel()
                    }
                )
        }
    }

    private func waitForJoinReady(stateManager: any ConversationStateManagerProtocol, inviteCode: String) async throws -> ConversationReadyResult {
        // Start the join flow first
        try await stateManager.joinConversation(inviteCode: inviteCode)

        // Poll for state changes since observer callbacks require MainActor which may be blocked
        while true {
            try Task.checkCancellation()

            let state = stateManager.currentState

            switch state {
            case .ready(let result):
                return result

            case .joinFailed(_, let error):
                throw CLIError.joinFailed(error.userFacingMessage)

            case .error(let error):
                throw error

            default:
                // Still waiting - poll every 100ms
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

// MARK: - Output Models

private struct ConversationInfo: Codable {
    let id: String
    let displayName: String
    let memberCount: Int
    let isUnread: Bool
    let isPinned: Bool
    let isMuted: Bool
    let kind: String
    let createdAt: Date
    let lastMessagePreview: String?
}

private struct CreateConversationResult: Codable {
    let conversationId: String
    let inviteSlug: String
}

private struct JoinResult: Codable {
    let status: String
    let conversationId: String?
}

private struct InviteResult: Codable {
    let inviteSlug: String
}

private struct MessageInfo: Codable {
    let id: String
    let conversationId: String
    let senderId: String
    let senderName: String
    let content: String
    let timestamp: Date
}

private struct SendResult: Codable {
    let success: Bool
}

private struct ReactResult: Codable {
    let success: Bool
    let action: String
}

private struct AccountInfo: Codable {
    let conversationCount: Int
    let environment: String
}
