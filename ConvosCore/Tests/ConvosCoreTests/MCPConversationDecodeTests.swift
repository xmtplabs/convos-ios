@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("MCP Conversation GRDB Decode Tests")
struct MCPConversationDecodeTests {

    @Test("Mock MCP conversation decodes through detailedConversationQuery")
    func testMCPConversationDecode() throws {
        let db = MockDatabaseManager.makeTestDatabase()

        let convId = "demo-mcp-conv-001"
        let inboxId = "test-inbox-001"
        let senderId = "mcp-sender-001"
        let now = Date()

        try db.dbWriter.write { db in
            // member table
            try DBMember(inboxId: inboxId).insert(db)
            try DBMember(inboxId: senderId).insert(db)

            // conversation
            let conversation = DBConversation(
                id: convId,
                inboxId: inboxId,
                clientId: "test-client-001",
                clientConversationId: convId,
                inviteTag: "test-invite-tag",
                creatorId: inboxId,
                kind: .dm,
                consent: .allowed,
                createdAt: now,
                name: "MCP Demo Chat",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: false,
                expiresAt: nil,
                debugInfo: ConversationDebugInfo(
                    epoch: 0,
                    maybeForked: false,
                    forkDetails: "",
                    localCommitLog: "",
                    remoteCommitLog: "",
                    commitLogForkStatus: .notForked
                ),
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                imageLastRenewed: nil,
                isUnused: false
            )
            try conversation.insert(db)

            // conversation members
            try DBConversationMember(
                conversationId: convId,
                inboxId: inboxId,
                role: .admin,
                consent: .allowed,
                createdAt: now
            ).insert(db)

            try DBConversationMember(
                conversationId: convId,
                inboxId: senderId,
                role: .member,
                consent: .allowed,
                createdAt: now
            ).insert(db)

            // member profiles
            try DBMemberProfile(
                conversationId: convId,
                inboxId: inboxId,
                name: "You",
                avatar: nil
            ).insert(db)

            try DBMemberProfile(
                conversationId: convId,
                inboxId: senderId,
                name: "MCP Bot",
                avatar: nil
            ).insert(db)

            // local state
            try ConversationLocalState(
                conversationId: convId,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: now,
                isMuted: false,
                pinnedOrder: nil
            ).insert(db)

            // text message
            try DBMessage(
                id: "msg-001",
                clientMessageId: "msg-001",
                conversationId: convId,
                senderId: senderId,
                dateNs: 1_000_000_000,
                date: now,
                sortId: 1,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "Hey! Check out this weather widget:",
                emoji: nil,
                invite: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil,
                mcpApp: nil
            ).insert(db)

            // MCP app message
            try DBMessage(
                id: "msg-002",
                clientMessageId: "msg-002",
                conversationId: convId,
                senderId: senderId,
                dateNs: 2_000_000_000,
                date: now.addingTimeInterval(1),
                sortId: 2,
                status: .published,
                messageType: .original,
                contentType: .mcpApp,
                text: nil,
                emoji: nil,
                invite: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil,
                mcpApp: MCPAppContent(
                    resourceURI: "ui://weather/forecast",
                    serverName: "Weather Server",
                    fallbackText: "Current weather: 72F, Sunny in San Francisco"
                )
            ).insert(db)
        }

        // Query using the same detailedConversationQuery
        let conversations = try db.dbReader.read { db in
            let details = try DBConversation
                .filter(DBConversation.Columns.id == convId)
                .filter(DBConversation.Columns.consent == Consent.allowed.rawValue)
                .filter(DBConversation.Columns.isUnused == false)
                .detailedConversationQuery()
                .fetchAll(db)

            return try details.composeConversations(from: db)
        }

        #expect(conversations.count == 1)

        let conv = conversations[0]
        #expect(conv.id == convId)
        #expect(conv.members.count == 2)

        #expect(conv.lastMessage != nil)
    }
}
