import Foundation
import GRDB

public protocol MyProfileWriterProtocol {
    func update(displayName: String, conversationId: String) async throws
    func update(avatar: Image?, conversationId: String) async throws
}

enum MyProfileWriterError: Error {
    case imageCompressionFailed
}

class MyProfileWriter: MyProfileWriterProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func update(displayName: String, conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }
        let trimmedDisplayName = {
            var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count > NameLimits.maxDisplayNameLength {
                name = String(name.prefix(NameLimits.maxDisplayNameLength))
            }
            return name
        }()
        let inboxId = inboxReady.client.inboxId
        let name = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        let profile = try await databaseWriter.write { db in
            let member = Member(inboxId: inboxId)
            try member.save(db)
            let profile = (try MemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId) ?? .init(
                conversationId: conversationId,
                inboxId: inboxId,
                name: name,
                avatar: nil
            )).with(name: name)
            try profile.save(db)
            return profile
        }

        try await group.updateProfile(profile)
    }

    func update(avatar: Image?, conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }
        let inboxId = inboxReady.client.inboxId
        let profile = try await databaseWriter.write { db in
            let member = Member(inboxId: inboxId)
            try member.save(db)
            if let foundProfile = try MemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId) {
                Log.info("Found profile: \(foundProfile)")
                return foundProfile
            } else {
                let profile = MemberProfile(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    name: nil,
                    avatar: nil
                )
                try profile.save(db)
                return profile
            }
        }

        guard let avatarImage = avatar else {
            // remove avatar image URL
            ImageCache.shared.removeImage(for: profile.hydrateProfile())
            let updatedProfile = profile.with(avatar: nil)
            try await group.updateProfile(updatedProfile)
            return
        }

        let hydratedProfile = profile.hydrateProfile()
        guard let compressedImageData = ImageCache.shared.resizeCacheAndGetData(
            avatarImage,
            for: hydratedProfile
        ) else {
            throw MyProfileWriterError.imageCompressionFailed
        }

        let uploadedURL = try await inboxReady.apiClient.uploadAttachment(
            data: compressedImageData,
            filename: "p-\(UUID().uuidString).jpg",
            contentType: "image/jpeg",
            acl: "public-read"
        )
        let updatedProfile = profile.with(avatar: uploadedURL)
        try await group.updateProfile(updatedProfile)

        // Cache the resized image with the uploaded URL as well
        if let image = Image(data: compressedImageData) {
            ImageCache.shared.setImage(image, for: uploadedURL)
        }

        try await databaseWriter.write { db in
            Log.info("Updated avatar for profile: \(updatedProfile)")
            try updatedProfile.save(db)
        }
    }
}
