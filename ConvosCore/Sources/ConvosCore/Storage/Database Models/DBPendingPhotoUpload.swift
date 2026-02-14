import Foundation
import GRDB

public enum PendingUploadState: String, Codable, DatabaseValueConvertible, Sendable {
    case uploading
    case sending
    case completed
    case failed
}

public struct DBPendingPhotoUpload: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName: String = "pendingPhotoUpload"

    public var id: String
    public var clientMessageId: String
    public var conversationId: String
    public var localCacheURL: String
    public var state: PendingUploadState
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        clientMessageId: String,
        conversationId: String,
        localCacheURL: String,
        state: PendingUploadState,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.clientMessageId = clientMessageId
        self.conversationId = conversationId
        self.localCacheURL = localCacheURL
        self.state = state
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public enum Columns {
        public static let id: Column = Column(CodingKeys.id)
        public static let clientMessageId: Column = Column(CodingKeys.clientMessageId)
        public static let conversationId: Column = Column(CodingKeys.conversationId)
        public static let localCacheURL: Column = Column(CodingKeys.localCacheURL)
        public static let state: Column = Column(CodingKeys.state)
        public static let errorMessage: Column = Column(CodingKeys.errorMessage)
        public static let createdAt: Column = Column(CodingKeys.createdAt)
        public static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }
}
