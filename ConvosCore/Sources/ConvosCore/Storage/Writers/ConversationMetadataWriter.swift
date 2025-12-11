import Combine
import Foundation
import GRDB
import UIKit
import XMTPiOS

// MARK: - Conversation Metadata Writer Protocol

public protocol ConversationMetadataWriterProtocol {
    func updateName(_ name: String, for conversationId: String) async throws
    func updateDescription(_ description: String, for conversationId: String) async throws
    func updateImageUrl(_ imageURL: String, for conversationId: String) async throws
    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws
    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws
    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func updateImage(_ image: UIImage, for conversation: Conversation) async throws
    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws
}

// MARK: - Conversation Metadata Writer Implementation

enum ConversationMetadataWriterError: Error {
    case failedImageCompression
}

final class ConversationMetadataWriter: ConversationMetadataWriterProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let inviteWriter: any InviteWriterProtocol

    init(inboxStateManager: any InboxStateManagerProtocol,
         inviteWriter: any InviteWriterProtocol,
         databaseWriter: any DatabaseWriter) {
        self.inboxStateManager = inboxStateManager
        self.inviteWriter = inviteWriter
        self.databaseWriter = databaseWriter
    }

    // MARK: - Conversation Metadata Updates

    func updateName(_ name: String, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        let truncatedName = name.count > NameLimits.maxConversationNameLength ? String(name.prefix(NameLimits.maxConversationNameLength)) : name

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateName(name: truncatedName)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(name: truncatedName)
            try updatedConversation.save(db)
            Log.info("Updated local conversation name for \(conversationId): \(truncatedName)")
            return updatedConversation
        }

        _ = try await inviteWriter .update(
            for: updatedConversation.id,
            name: updatedConversation.name,
            description: updatedConversation.description,
            imageURL: updatedConversation.imageURLString
        )

        Log.info("Updated conversation name for \(conversationId): \(truncatedName)")
    }

    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateExpiresAt(date: expiresAt)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(expiresAt: expiresAt)
            try updatedConversation.save(db)
            return updatedConversation
        }

        _ = try await inviteWriter.update(
            for: updatedConversation.id,
            name: updatedConversation.name,
            description: updatedConversation.description,
            imageURL: updatedConversation.imageURLString
        )

        Log.info("Updated conversation expiresAt for \(conversationId): \(expiresAt)")
    }

    func updateDescription(_ description: String, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateDescription(description: description)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(description: description)
            try updatedConversation.save(db)
            Log.info("Updated local conversation description for \(conversationId): \(description)")
            return updatedConversation
        }

        _ = try await inviteWriter.update(
            for: updatedConversation.id,
            name: updatedConversation.name,
            description: updatedConversation.description,
            imageURL: updatedConversation.imageURLString
        )

        Log.info("Updated conversation description for \(conversationId): \(description)")
    }

    func updateImage(_ image: UIImage, for conversation: Conversation) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        // Resize, cache, and get JPEG data in one pass
        guard let compressedImageData = ImageCache.shared.resizeCacheAndGetData(
            image,
            for: conversation
        ) else {
            throw ConversationMetadataWriterError.failedImageCompression
        }

        let assetKey = "conversation-image-\(UUID().uuidString).jpg"

        _ = try await inboxReady.apiClient.uploadAttachmentAndExecute(
            data: compressedImageData,
            assetKey: assetKey
        ) { uploadedAssetKey in
            do {
                try await self.updateImageUrl(uploadedAssetKey, for: conversation.id)
            } catch {
                Log.error("Failed updating conversation image URL: \(error.localizedDescription)")
            }
        }
    }

    func updateImageUrl(_ imageURL: String, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateImageUrl(imageUrl: imageURL)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(imageURLString: imageURL)
            try updatedConversation.save(db)
            Log.info("Updated local conversation image for \(conversationId): \(imageURL)")
            return updatedConversation
        }

        _ = try await inviteWriter.update(
            for: updatedConversation.id,
            name: updatedConversation.name,
            description: updatedConversation.description,
            imageURL: updatedConversation.imageURLString
        )

        Log.info("Updated conversation image for \(conversationId): \(imageURL)")
    }

    // MARK: - Member Management

    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        _ = try await group.addMembers(inboxIds: memberInboxIds)

        try await databaseWriter.write { db in
            for memberInboxId in memberInboxIds {
                let conversationMember = DBConversationMember(
                    conversationId: conversationId,
                    inboxId: memberInboxId,
                    role: .member,
                    consent: .allowed,
                    createdAt: Date()
                )
                try conversationMember.save(db)
                Log.info("Added local conversation member \(memberInboxId) to \(conversationId)")
            }
        }

        Log.info("Added members to conversation \(conversationId): \(memberInboxIds)")
    }

    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeMembers(inboxIds: memberInboxIds)

        try await databaseWriter.write { db in
            for memberInboxId in memberInboxIds {
                try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversationId)
                    .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                    .deleteAll(db)
                Log.info("Removed local conversation member \(memberInboxId) from \(conversationId)")
            }
        }

        Log.info("Removed members from conversation \(conversationId): \(memberInboxIds)")
    }

    // MARK: - Admin Management

    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.addAdmin(inboxId: memberInboxId)

        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .admin)
                try updatedMember.save(db)
                Log.info("Updated local member \(memberInboxId) role to admin in \(conversationId)")
            }
        }

        Log.info("Promoted \(memberInboxId) to admin in conversation \(conversationId)")
    }

    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeAdmin(inboxId: memberInboxId)
        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .member)
                try updatedMember.save(db)
                Log.info("Updated local member \(memberInboxId) role to member in \(conversationId)")
            }
        }

        Log.info("Demoted \(memberInboxId) from admin in conversation \(conversationId)")
    }

    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.addSuperAdmin(inboxId: memberInboxId)
        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .superAdmin)
                try updatedMember.save(db)
                Log.info("Updated local member \(memberInboxId) role to superAdmin in \(conversationId)")
            }
        }

        Log.info("Promoted \(memberInboxId) to super admin in conversation \(conversationId)")
    }

    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeSuperAdmin(inboxId: memberInboxId)
        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .admin)
                try updatedMember.save(db)
                Log.info("Updated local member \(memberInboxId) role to admin in \(conversationId)")
            }
        }

        Log.info("Demoted \(memberInboxId) from super admin in conversation \(conversationId)")
    }
}

// MARK: - Conversation Metadata Errors

enum ConversationMetadataError: LocalizedError {
    case clientNotAvailable
    case conversationNotFound(conversationId: String)
    case memberNotFound(memberInboxId: String)
    case insufficientPermissions

    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "XMTP client is not available"
        case .conversationNotFound(let conversationId):
            return "Conversation not found: \(conversationId)"
        case .memberNotFound(let memberInboxId):
            return "Member not found: \(memberInboxId)"
        case .insufficientPermissions:
            return "Insufficient permissions to perform this action"
        }
    }
}
