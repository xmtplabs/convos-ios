import Foundation

extension DBAgentBuilderSummary {
    /// Decode the JSON attachment blob back into the public summary type.
    /// Throws on malformed JSON — callers should treat that as "no summary"
    /// rather than surface the error, since the UI degrades gracefully to the
    /// natural message list.
    public func toAgentBuilderSummary() throws -> AgentBuilderSummary {
        let attachmentsData: Data = attachmentsJSON.data(using: .utf8) ?? Data()
        let attachments: [AgentBuilderSummaryAttachment] = try JSONDecoder()
            .decode([AgentBuilderSummaryAttachment].self, from: attachmentsData)
        // `bundledMessageIdsJSON` is empty on summaries written before this
        // column existed; treat that as "no ids tracked" rather than fail to
        // decode. Same fallback for malformed JSON — the timestamp-based
        // agent-side cutoff still applies, so older summaries degrade
        // gracefully (they just lose the explicit user-side filter).
        let bundledIds: Set<String> = {
            guard let data = bundledMessageIdsJSON.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(array)
        }()
        let cloudConnectionIds: [String: String] = {
            guard let data = cloudConnectionIdsJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }()
        return AgentBuilderSummary(
            id: UUID(uuidString: summaryId) ?? UUID(),
            prompt: prompt,
            attachments: attachments,
            createdAt: createdAt,
            cutoffDate: cutoffDate,
            bundledMessageIds: bundledIds,
            cloudConnectionIds: cloudConnectionIds,
            connectionsAppliedAt: connectionsAppliedAt,
            existingConversation: existingConversation
        )
    }
}

extension AgentBuilderSummary {
    /// Encode for storage. Attachments serialize to JSON (base64 inside for
    /// any `Data` thumbnails). `bundledMessageIds` serializes as a JSON array
    /// (Sets aren't directly JSON-encodable; the conversion back is in
    /// `toAgentBuilderSummary`). `cloudConnectionIds` serialize as a JSON
    /// object keyed by connection `rawValue`.
    public func toDBAgentBuilderSummary(conversationId: String) throws -> DBAgentBuilderSummary {
        let attachmentsData: Data = try JSONEncoder().encode(attachments)
        let attachmentsJSON: String = String(data: attachmentsData, encoding: .utf8) ?? "[]"
        let bundledIdsArray: [String] = Array(bundledMessageIds)
        let bundledIdsData: Data = try JSONEncoder().encode(bundledIdsArray)
        let bundledMessageIdsJSON: String = String(data: bundledIdsData, encoding: .utf8) ?? "[]"
        let cloudConnectionIdsData: Data = try JSONEncoder().encode(cloudConnectionIds)
        let cloudConnectionIdsJSON: String = String(data: cloudConnectionIdsData, encoding: .utf8) ?? "{}"
        return DBAgentBuilderSummary(
            conversationId: conversationId,
            summaryId: id.uuidString,
            prompt: prompt,
            attachmentsJSON: attachmentsJSON,
            createdAt: createdAt,
            cutoffDate: cutoffDate,
            bundledMessageIdsJSON: bundledMessageIdsJSON,
            cloudConnectionIdsJSON: cloudConnectionIdsJSON,
            connectionsAppliedAt: connectionsAppliedAt,
            existingConversation: existingConversation
        )
    }
}
