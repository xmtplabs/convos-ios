import Combine
import Foundation
import GRDB

public struct PhotoPreferences: Hashable, Sendable {
    public let conversationId: String
    public let autoReveal: Bool
    public let hasRevealedFirst: Bool

    public var shouldBlurPhotos: Bool {
        !hasRevealedFirst || !autoReveal
    }
}

public protocol PhotoPreferencesRepositoryProtocol: Sendable {
    func preferences(for conversationId: String) async throws -> PhotoPreferences?
    func preferencesPublisher(for conversationId: String) -> AnyPublisher<PhotoPreferences?, Never>
}

public final class PhotoPreferencesRepository: PhotoPreferencesRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func preferences(for conversationId: String) async throws -> PhotoPreferences? {
        try await databaseReader.read { db in
            try DBPhotoPreferences
                .filter(DBPhotoPreferences.Columns.conversationId == conversationId)
                .fetchOne(db)
                .map { dbPrefs in
                    PhotoPreferences(
                        conversationId: dbPrefs.conversationId,
                        autoReveal: dbPrefs.autoReveal,
                        hasRevealedFirst: dbPrefs.hasRevealedFirst
                    )
                }
        }
    }

    public func preferencesPublisher(for conversationId: String) -> AnyPublisher<PhotoPreferences?, Never> {
        ValueObservation
            .tracking { db in
                try DBPhotoPreferences
                    .filter(DBPhotoPreferences.Columns.conversationId == conversationId)
                    .fetchOne(db)
                    .map { dbPrefs in
                        PhotoPreferences(
                            conversationId: dbPrefs.conversationId,
                            autoReveal: dbPrefs.autoReveal,
                            hasRevealedFirst: dbPrefs.hasRevealedFirst
                        )
                    }
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }
}
