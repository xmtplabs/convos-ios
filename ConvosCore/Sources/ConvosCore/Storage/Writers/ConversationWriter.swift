import Foundation
import GRDB
import XMTPiOS

enum ConversationWriterError: Error {
    case inboxNotFound(String)
    case expectedGroup
    case invalidInvite(String)
}

protocol ConversationWriterProtocol {
    @discardableResult
    func store(conversation: XMTPiOS.Group, inboxId: String) async throws -> DBConversation
    @discardableResult
    func storeWithLatestMessages(conversation: XMTPiOS.Group, inboxId: String) async throws -> DBConversation
    func createPlaceholderConversation(
        draftConversationId: String?,
        for signedInvite: SignedInvite,
        inboxId: String
    ) async throws -> String
}

/// Writer for persisting conversations and their members to the database
///
/// ConversationWriter handles converting XMTP conversations to database representations
/// and managing all related data including members, profiles, invites, and messages.
/// Handles both initial storage and updates, with special logic for matching
/// placeholder conversations created during invite flows.
class ConversationWriter: ConversationWriterProtocol {
    private let databaseWriter: any DatabaseWriter
    private let inviteWriter: any InviteWriterProtocol
    private let messageWriter: any IncomingMessageWriterProtocol
    private let localStateWriter: any ConversationLocalStateWriterProtocol

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         messageWriter: any IncomingMessageWriterProtocol) {
        self.databaseWriter = databaseWriter
        self.inviteWriter = InviteWriter(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
        self.messageWriter = messageWriter
        self.localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseWriter)
    }

    func store(conversation: XMTPiOS.Group, inboxId: String) async throws -> DBConversation {
        return try await _store(conversation: conversation, inboxId: inboxId)
    }

    func storeWithLatestMessages(conversation: XMTPiOS.Group, inboxId: String) async throws -> DBConversation {
        return try await _store(conversation: conversation, inboxId: inboxId, withLatestMessages: true)
    }

    func createPlaceholderConversation(
        draftConversationId: String? = nil,
        for signedInvite: SignedInvite,
        inboxId: String
    ) async throws -> String {
        let draftConversationId = draftConversationId ?? DBConversation.generateDraftConversationId()

        // Create the draft conversation and necessary records
        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        // validate that the invite contains a non-empty creator inbox ID
        guard !creatorInboxId.isEmpty else {
            throw ConversationWriterError.invalidInvite("Empty creator inbox ID")
        }

        let conversation = try await databaseWriter.write { db in
            // Look up clientId from inbox
            guard let inbox = try DBInbox.fetchOne(db, id: inboxId) else {
                throw ConversationWriterError.inboxNotFound(inboxId)
            }

            let conversation = DBConversation(
                id: draftConversationId,
                inboxId: inboxId,
                clientId: inbox.clientId,
                clientConversationId: draftConversationId,
                inviteTag: signedInvite.invitePayload.tag,
                creatorId: creatorInboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: signedInvite.name,
                description: signedInvite.description_p,
                imageURLString: signedInvite.imageURL,
                expiresAt: signedInvite.conversationExpiresAt,
                debugInfo: .empty
            )
            try conversation.save(db)
            let memberProfile = DBMemberProfile(
                conversationId: draftConversationId,
                inboxId: creatorInboxId,
                name: nil,
                avatar: nil
            )
            let member = DBMember(inboxId: creatorInboxId)
            try member.save(db)
            try memberProfile.save(db)

            let localState = ConversationLocalState(
                conversationId: conversation.id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil
            )
            try localState.save(db)

            let conversationMember = DBConversationMember(
                conversationId: conversation.id,
                inboxId: creatorInboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date()
            )
            try conversationMember.save(db)

            Log.info("Created placeholder conversation for invite")
            return conversation
        }

        return conversation.id
    }

    private func _store(
        conversation: XMTPiOS.Group,
        inboxId: String,
        withLatestMessages: Bool = false
    ) async throws -> DBConversation {
        // Extract conversation metadata
        let metadata = try await extractConversationMetadata(from: conversation)
        let members = try await conversation.members
        let dbMembers = members.map { $0.dbRepresentation(conversationId: conversation.id) }
        let memberProfiles = try conversation.memberProfiles

        // Create database representation
        let dbConversation = try await createDBConversation(
            from: conversation,
            metadata: metadata,
            inboxId: inboxId
        )

        // Save to database
        try await saveConversationToDatabase(
            dbConversation: dbConversation,
            dbMembers: dbMembers,
            memberProfiles: memberProfiles
        )

        // Prefetch encrypted profile images in background
        prefetchEncryptedImages(profiles: memberProfiles, group: conversation)

        // Create invite
        _ = try await inviteWriter.generate(
            for: dbConversation,
            expiresAt: nil,
            expiresAfterUse: false
        )

        // Fetch and store latest messages if requested
        if withLatestMessages {
            try await fetchAndStoreLatestMessages(for: conversation, dbConversation: dbConversation)
        }

        // Store last message
        let lastMessage = try await conversation.lastMessage()
        if let lastMessage {
            let result = try await messageWriter.store(
                message: lastMessage,
                for: dbConversation
            )
            Log.info("Saved last message: \(result)")
        }

        return dbConversation
    }

    // MARK: - Helper Methods

    private struct ConversationMetadata {
        let kind: ConversationKind
        let name: String?
        let description: String?
        let imageURLString: String?
        let expiresAt: Date?
        let debugInfo: ConversationDebugInfo
    }

    private func extractConversationMetadata(from conversation: XMTPiOS.Group) async throws -> ConversationMetadata {
        let debugInfo = try await conversation.getDebugInformation().toDBDebugInfo()
        return ConversationMetadata(
            kind: .group,
            name: try conversation.name(),
            description: try conversation.description(),
            imageURLString: try conversation.imageUrl(),
            expiresAt: try conversation.expiresAt,
            debugInfo: debugInfo
        )
    }

    private func createDBConversation(
        from conversation: XMTPiOS.Group,
        metadata: ConversationMetadata,
        inboxId: String
    ) async throws -> DBConversation {
        // Look up clientId from inbox
        let clientId = try await databaseWriter.read { db in
            guard let inbox = try DBInbox.fetchOne(db, id: inboxId) else {
                throw ConversationWriterError.inboxNotFound(inboxId)
            }
            return inbox.clientId
        }

        return DBConversation(
            id: conversation.id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: conversation.id,
            inviteTag: try conversation.inviteTag,
            creatorId: try await conversation.creatorInboxId(),
            kind: metadata.kind,
            consent: try conversation.consentState().consent,
            createdAt: conversation.createdAt,
            name: metadata.name,
            description: metadata.description,
            imageURLString: metadata.imageURLString,
            expiresAt: metadata.expiresAt,
            debugInfo: metadata.debugInfo
        )
    }

    private func saveConversationToDatabase(
        dbConversation: DBConversation,
        dbMembers: [DBConversationMember],
        memberProfiles: [DBMemberProfile]
    ) async throws {
        try await databaseWriter.write { [weak self] db in
            guard let self else { return }
            let creator = DBMember(inboxId: dbConversation.creatorId)
            try creator.save(db)

            // Save conversation (handle local conversation updates)
            try saveConversation(dbConversation, in: db)

            // Save local state
            let localState = ConversationLocalState(
                conversationId: dbConversation.id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date.distantPast,
                isMuted: false,
                pinnedOrder: nil
            )
            try localState.insert(db, onConflict: .ignore)

            // Delete old members
            try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == dbConversation.id)
                .deleteAll(db)
            // Save members
            try saveMembers(dbMembers, in: db)
            // Update profiles - ensure Member exists first
            try memberProfiles.forEach { profile in
                let member = DBMember(inboxId: profile.inboxId)
                try member.save(db)
                try profile.save(db)
            }
        }
    }

    private func saveConversation(_ dbConversation: DBConversation, in db: Database) throws {
        let firstTimeSeeingConversationExpired: Bool
        if let localConversation = try DBConversation
            .filter(DBConversation.Columns.inviteTag == dbConversation.inviteTag)
            .filter(DBConversation.Columns.clientConversationId != dbConversation.clientConversationId)
            .fetchOne(db) {
            // Keep using the same local id
            Log.info("Found local conversation \(localConversation.clientConversationId) for incoming \(dbConversation.id)")
            let updatedConversation = dbConversation
                .with(clientConversationId: localConversation.clientConversationId)
            try updatedConversation.save(db, onConflict: .replace)
            firstTimeSeeingConversationExpired = updatedConversation.isExpired && updatedConversation.expiresAt != localConversation.expiresAt
            Log.info("Updated incoming conversation with local \(localConversation.clientConversationId)")
        } else {
            do {
                try dbConversation.save(db)
                firstTimeSeeingConversationExpired = dbConversation.isExpired
            } catch {
                Log.error("Failed saving incoming conversation \(dbConversation.id): \(error)")
                throw error
            }
        }

        if firstTimeSeeingConversationExpired {
            Log.info("Encountered expired conversation for the first time.")
        }
    }

    private func saveMembers(_ dbMembers: [DBConversationMember], in db: Database) throws {
        for member in dbMembers {
            try DBMember(inboxId: member.inboxId).save(db)
            try member.save(db)
            // fetch from description
            let memberProfile = DBMemberProfile(
                conversationId: member.conversationId,
                inboxId: member.inboxId,
                name: nil,
                avatar: nil
            )
            try? memberProfile.insert(db, onConflict: .ignore)
        }
    }

    private func fetchAndStoreLatestMessages(
        for conversation: XMTPiOS.Group,
        dbConversation: DBConversation
    ) async throws {
        Log.info("Attempting to fetch latest messages...")

        // Get the timestamp of the last stored message
        let lastMessageNs = try await getLastMessageTimestamp(for: conversation.id)

        // Fetch new messages
        let messages = try await conversation.messages(afterNs: lastMessageNs)
        guard !messages.isEmpty else { return }

        Log.info("Found \(messages.count) new messages, catching up...")

        // Store messages and track if conversation should be marked unread
        var marksConversationAsUnread = false
        for message in messages {
            Log.info("Catching up with message sent at: \(message.sentAt.nanosecondsSince1970)")
            let result = try await messageWriter.store(message: message, for: dbConversation)
            if result.contentType.marksConversationAsUnread {
                marksConversationAsUnread = true
            }
            Log.info("Saved caught up message sent at: \(message.sentAt.nanosecondsSince1970)")
        }

        // Update unread status if needed
        if marksConversationAsUnread {
            try await localStateWriter.setUnread(true, for: conversation.id)
        }
    }

    private func getLastMessageTimestamp(for conversationId: String) async throws -> Int64? {
        try await databaseWriter.read { db in
            let lastMessage = DBConversation.association(
                to: DBConversation.lastMessageCTE,
                on: { conversation, lastMessage in
                    conversation.id == lastMessage.conversationId
                }
            ).forKey("latestMessage")
            let result = try DBConversation
                .filter(DBConversation.Columns.id == conversationId)
                .with(DBConversation.lastMessageCTE)
                .including(optional: lastMessage)
                .asRequest(of: DBConversationLatestMessage.self)
                .fetchOne(db)
            return result?.latestMessage?.dateNs
        }
    }

    private func prefetchEncryptedImages(profiles: [DBMemberProfile], group: XMTPiOS.Group) {
        let encryptedProfiles = profiles.filter { $0.avatarSalt != nil && $0.avatarNonce != nil }
        guard !encryptedProfiles.isEmpty else { return }

        let groupKey: Data? = try? group.imageEncryptionKey

        Task.detached(priority: .background) {
            guard let groupKey else {
                Log.info("No image encryption key for group, skipping prefetch")
                return
            }

            let prefetcher = EncryptedImagePrefetcher()
            await prefetcher.prefetchProfileImages(
                profiles: encryptedProfiles,
                groupKey: groupKey
            )
        }
    }
}

// MARK: - Helper Extensions

extension Attachment {
    func saveToTmpFile() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + filename
        let fileURL = tempDir.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        return fileURL
    }
}

fileprivate extension XMTPiOS.Member {
    func dbRepresentation(conversationId: String) -> DBConversationMember {
        .init(conversationId: conversationId,
              inboxId: inboxId,
              role: permissionLevel.role,
              consent: consentState.memberConsent,
              createdAt: Date())
    }
}

fileprivate extension XMTPiOS.PermissionLevel {
    var role: MemberRole {
        switch self {
        case .SuperAdmin: return .superAdmin
        case .Admin: return .admin
        case .Member: return .member
        }
    }
}

enum ConversationInviteTagError: Error {
    case attemptedFetchingInviteTagForDM
}

extension XMTPiOS.Conversation {
    var creatorInboxId: String {
        get async throws {
            switch self {
            case .group(let group):
                return try await group.creatorInboxId()
            case .dm(let dm):
                return try await dm.creatorInboxId()
            }
        }
    }

    var inviteTag: String {
        get throws {
            switch self {
            case .group(let group):
                return try group.inviteTag
            case .dm:
                throw ConversationInviteTagError.attemptedFetchingInviteTagForDM
            }
        }
    }
}

fileprivate extension XMTPiOS.ConsentState {
    var memberConsent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }

    var consent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

fileprivate extension XMTPiOS.ConversationDebugInfo {
    func toDBDebugInfo() -> ConversationDebugInfo {
        ConversationDebugInfo(
            epoch: epoch,
            maybeForked: maybeForked,
            forkDetails: forkDetails,
            localCommitLog: localCommitLog,
            remoteCommitLog: remoteCommitLog,
            commitLogForkStatus: commitLogForkStatus.toDBStatus()
        )
    }
}

fileprivate extension XMTPiOS.CommitLogForkStatus {
    func toDBStatus() -> CommitLogForkStatus {
        switch self {
        case .forked: return .forked
        case .notForked: return .notForked
        case .unknown: return .unknown
        }
    }
}
