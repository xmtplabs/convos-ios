import Combine
import Foundation
import GRDB

public struct PhotoPreferences: Hashable, Sendable {
    public let conversationId: String
    public let sendReadReceipts: Bool?

    public init(conversationId: String, sendReadReceipts: Bool?) {
        self.conversationId = conversationId
        self.sendReadReceipts = sendReadReceipts
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
                        sendReadReceipts: dbPrefs.sendReadReceipts
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
                            sendReadReceipts: dbPrefs.sendReadReceipts
                        )
                    }
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }
}
