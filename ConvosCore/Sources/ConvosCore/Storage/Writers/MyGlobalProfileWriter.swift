import CryptoKit
import Foundation
import GRDB

/// Writes the local user's global profile (`DBMyProfile`). Local-only; does
/// not publish to any group.
public protocol MyGlobalProfileWriterProtocol: Sendable {
    func save(name: String?, imageData: Data?, imageAssetIdentifier: String?, metadata: ProfileMetadata?) async throws
    func update(name: String?) async throws
    func update(imageData: Data?, imageAssetIdentifier: String?) async throws
    func update(metadata: ProfileMetadata?) async throws
    func delete() async throws
}

final class MyGlobalProfileWriter: MyGlobalProfileWriterProtocol, @unchecked Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
    }

    func save(name: String?, imageData: Data?, imageAssetIdentifier: String?, metadata: ProfileMetadata?) async throws {
        let inboxId = try await currentInboxId()
        let row = DBMyProfile(
            inboxId: inboxId,
            name: trim(name),
            imageData: imageData,
            imageAssetIdentifier: imageData == nil ? nil : imageAssetIdentifier,
            imageContentDigest: Self.digest(of: imageData),
            metadata: (metadata?.isEmpty ?? true) ? nil : metadata,
            updatedAt: Date()
        )
        try await databaseWriter.write { db in
            try row.save(db)
        }
    }

    func update(name: String?) async throws {
        let resolved = trim(name)
        try await mutate { current in
            DBMyProfile(
                inboxId: current.inboxId,
                name: resolved,
                imageData: current.imageData,
                imageAssetIdentifier: current.imageAssetIdentifier,
                imageContentDigest: current.imageContentDigest,
                metadata: current.metadata,
                updatedAt: Date()
            )
        }
    }

    func update(imageData: Data?, imageAssetIdentifier: String?) async throws {
        try await mutate { current in
            DBMyProfile(
                inboxId: current.inboxId,
                name: current.name,
                imageData: imageData,
                imageAssetIdentifier: imageData == nil ? nil : imageAssetIdentifier,
                imageContentDigest: Self.digest(of: imageData),
                metadata: current.metadata,
                updatedAt: Date()
            )
        }
    }

    func update(metadata: ProfileMetadata?) async throws {
        try await mutate { current in
            DBMyProfile(
                inboxId: current.inboxId,
                name: current.name,
                imageData: current.imageData,
                imageAssetIdentifier: current.imageAssetIdentifier,
                imageContentDigest: current.imageContentDigest,
                metadata: (metadata?.isEmpty ?? true) ? nil : metadata,
                updatedAt: Date()
            )
        }
    }

    /// Base64-encoded SHA-256 of the image bytes. Used as a stable, content-addressed
    /// identifier — independent of photos library access — so activate-sync can detect
    /// when the image changed and re-upload to per-conversation members.
    private static func digest(of imageData: Data?) -> String? {
        guard let imageData else { return nil }
        return Data(SHA256.hash(data: imageData)).base64EncodedString()
    }

    func delete() async throws {
        let inboxId = try await currentInboxId()
        try await databaseWriter.write { db in
            _ = try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == inboxId)
                .deleteAll(db)
        }
    }

    private func mutate(_ transform: @Sendable @escaping (DBMyProfile) -> DBMyProfile) async throws {
        let inboxId = try await currentInboxId()
        try await databaseWriter.write { db in
            let current = try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == inboxId)
                .fetchOne(db) ?? DBMyProfile(inboxId: inboxId)
            try transform(current).save(db)
        }
    }

    private func currentInboxId() async throws -> String {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        return inboxReady.client.inboxId
    }

    private func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > NameLimits.maxDisplayNameLength {
            trimmed = String(trimmed.prefix(NameLimits.maxDisplayNameLength))
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
