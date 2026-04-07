import Foundation
import GRDB

struct DBVoiceMemoTranscript: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "voiceMemoTranscript"

    enum Columns {
        static let messageId: Column = Column(CodingKeys.messageId)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let attachmentKey: Column = Column(CodingKeys.attachmentKey)
        static let status: Column = Column(CodingKeys.status)
        static let text: Column = Column(CodingKeys.text)
        static let errorDescription: Column = Column(CodingKeys.errorDescription)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let messageId: String
    let conversationId: String
    let attachmentKey: String
    let status: String
    let text: String?
    let errorDescription: String?
    let createdAt: Date
    let updatedAt: Date
}

extension DBVoiceMemoTranscript {
    init(_ transcript: VoiceMemoTranscript) {
        self.messageId = transcript.messageId
        self.conversationId = transcript.conversationId
        self.attachmentKey = transcript.attachmentKey
        self.status = transcript.status.rawValue
        self.text = transcript.text
        self.errorDescription = transcript.errorDescription
        self.createdAt = transcript.createdAt
        self.updatedAt = transcript.updatedAt
    }

    var model: VoiceMemoTranscript {
        VoiceMemoTranscript(
            messageId: messageId,
            conversationId: conversationId,
            attachmentKey: attachmentKey,
            status: VoiceMemoTranscriptStatus(rawValue: status) ?? .pending,
            text: text,
            errorDescription: errorDescription,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
