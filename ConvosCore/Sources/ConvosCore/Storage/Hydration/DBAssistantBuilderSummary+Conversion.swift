import Foundation

extension DBAssistantBuilderSummary {
    /// Decode the JSON attachment blob back into the public summary type.
    /// Throws on malformed JSON — callers should treat that as "no summary"
    /// rather than surface the error, since the UI degrades gracefully to the
    /// natural message list.
    public func toAssistantBuilderSummary() throws -> AssistantBuilderSummary {
        let attachmentsData: Data = attachmentsJSON.data(using: .utf8) ?? Data()
        let attachments: [AssistantBuilderSummaryAttachment] = try JSONDecoder()
            .decode([AssistantBuilderSummaryAttachment].self, from: attachmentsData)
        return AssistantBuilderSummary(
            id: UUID(uuidString: summaryId) ?? UUID(),
            prompt: prompt,
            attachments: attachments,
            createdAt: createdAt,
            cutoffDate: cutoffDate
        )
    }
}

extension AssistantBuilderSummary {
    /// Encode for storage. Attachments serialize to JSON (base64 inside for
    /// any `Data` thumbnails).
    public func toDBAssistantBuilderSummary(conversationId: String) throws -> DBAssistantBuilderSummary {
        let attachmentsData: Data = try JSONEncoder().encode(attachments)
        let attachmentsJSON: String = String(data: attachmentsData, encoding: .utf8) ?? "[]"
        return DBAssistantBuilderSummary(
            conversationId: conversationId,
            summaryId: id.uuidString,
            prompt: prompt,
            attachmentsJSON: attachmentsJSON,
            createdAt: createdAt,
            cutoffDate: cutoffDate
        )
    }
}
