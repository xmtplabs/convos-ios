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
        // `bundledMessageIdsJSON` is empty on summaries written before this
        // column existed; treat that as "no ids tracked" rather than fail to
        // decode. Same fallback for malformed JSON — the timestamp-based
        // assistant-side cutoff still applies, so older summaries degrade
        // gracefully (they just lose the explicit user-side filter).
        let bundledIds: Set<String> = {
            guard let data = bundledMessageIdsJSON.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(array)
        }()
        return AssistantBuilderSummary(
            id: UUID(uuidString: summaryId) ?? UUID(),
            prompt: prompt,
            attachments: attachments,
            createdAt: createdAt,
            cutoffDate: cutoffDate,
            bundledMessageIds: bundledIds
        )
    }
}

extension AssistantBuilderSummary {
    /// Encode for storage. Attachments serialize to JSON (base64 inside for
    /// any `Data` thumbnails). `bundledMessageIds` serializes as a JSON array
    /// (Sets aren't directly JSON-encodable; the conversion back is in
    /// `toAssistantBuilderSummary`).
    public func toDBAssistantBuilderSummary(conversationId: String) throws -> DBAssistantBuilderSummary {
        let attachmentsData: Data = try JSONEncoder().encode(attachments)
        let attachmentsJSON: String = String(data: attachmentsData, encoding: .utf8) ?? "[]"
        let bundledIdsArray: [String] = Array(bundledMessageIds)
        let bundledIdsData: Data = try JSONEncoder().encode(bundledIdsArray)
        let bundledMessageIdsJSON: String = String(data: bundledIdsData, encoding: .utf8) ?? "[]"
        return DBAssistantBuilderSummary(
            conversationId: conversationId,
            summaryId: id.uuidString,
            prompt: prompt,
            attachmentsJSON: attachmentsJSON,
            createdAt: createdAt,
            cutoffDate: cutoffDate,
            bundledMessageIdsJSON: bundledMessageIdsJSON
        )
    }
}
