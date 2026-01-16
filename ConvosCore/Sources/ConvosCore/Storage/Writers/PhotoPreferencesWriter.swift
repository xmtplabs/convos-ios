import Foundation
import GRDB

public protocol PhotoPreferencesWriterProtocol: Sendable {
    func setAutoReveal(_ autoReveal: Bool, for conversationId: String) async throws
    func setHasRevealedFirst(_ hasRevealedFirst: Bool, for conversationId: String) async throws
}

public final class PhotoPreferencesWriter: PhotoPreferencesWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func setAutoReveal(_ autoReveal: Bool, for conversationId: String) async throws {
        try await updatePreferences(for: conversationId) { prefs in
            prefs.with(autoReveal: autoReveal)
        }
    }

    public func setHasRevealedFirst(_ hasRevealedFirst: Bool, for conversationId: String) async throws {
        try await updatePreferences(for: conversationId) { prefs in
            prefs.with(hasRevealedFirst: hasRevealedFirst)
        }
    }

    private func updatePreferences(
        for conversationId: String,
        _ update: @escaping (DBPhotoPreferences) -> DBPhotoPreferences
    ) async throws {
        try await databaseWriter.write { db in
            guard try DBConversation.fetchOne(db, key: conversationId) != nil else {
                throw PhotoPreferencesWriterError.conversationNotFound
            }

            let current = try DBPhotoPreferences
                .filter(DBPhotoPreferences.Columns.conversationId == conversationId)
                .fetchOne(db)
                ?? DBPhotoPreferences.defaultPreferences(for: conversationId)

            let updated = update(current)
            try updated.save(db)
        }
    }
}

public enum PhotoPreferencesWriterError: Error {
    case conversationNotFound
}
