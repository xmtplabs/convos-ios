import Foundation

public enum VoiceMemoTranscriptStatus: String, Codable, Hashable, Sendable {
    /// Display-only state for an incoming voice memo that the app has not yet been
    /// asked to transcribe (typically because the user has not granted speech
    /// recognition permission). This case is never persisted; the database only
    /// holds rows for transcripts that have actually started, completed, or failed.
    case notRequested = "not_requested"
    case pending
    case completed
    case failed
}

public struct VoiceMemoTranscript: Codable, Hashable, Sendable {
    public let messageId: String
    public let conversationId: String
    public let attachmentKey: String
    public let status: VoiceMemoTranscriptStatus
    public let text: String?
    public let errorDescription: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        status: VoiceMemoTranscriptStatus,
        text: String? = nil,
        errorDescription: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.messageId = messageId
        self.conversationId = conversationId
        self.attachmentKey = attachmentKey
        self.status = status
        self.text = text
        self.errorDescription = errorDescription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
