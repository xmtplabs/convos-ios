import Foundation
import GRDB

public struct AssistantFile: Sendable, Hashable, Identifiable {
    public let id: String
    public let filename: String?
    public let mimeType: String?
    public let date: Date
    public let attachmentKey: String
    public let thumbnailDataBase64: String?

    public var displayName: String {
        filename ?? "Untitled"
    }

    public var formattedDate: String {
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
    }

    public var mediaType: MediaType {
        guard let mimeType else { return .file }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return .file
    }
}

public struct AssistantLink: Sendable, Hashable, Identifiable {
    public let id: String
    public let url: String
    public let title: String?
    public let siteName: String?
    public let imageURL: String?
    public let date: Date

    public var displayTitle: String {
        title ?? displayHost
    }

    public var displayHost: String {
        URL(string: url)?.host ?? url
    }

    public var formattedDate: String {
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
    }

    public var resolvedURL: URL? {
        URL(string: url)
    }
}

public final class AssistantFilesLinksRepository: Sendable {
    private let dbReader: any DatabaseReader
    private let conversationId: String

    public init(dbReader: any DatabaseReader, conversationId: String) {
        self.dbReader = dbReader
        self.conversationId = conversationId
    }

    public func fetchFiles() async throws -> [AssistantFile] {
        try await dbReader.read { [conversationId] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id, m.date, m.attachmentUrls
                FROM message m
                INNER JOIN memberProfile mp
                    ON mp.inboxId = m.senderId AND mp.conversationId = m.conversationId
                WHERE m.conversationId = ?
                    AND m.contentType = 'attachments'
                    AND mp.memberKind IN ('agent', 'agent:convos', 'agent:user-oauth')
                ORDER BY m.date DESC
                """,
                arguments: [conversationId]
            )

            return rows.compactMap { row -> AssistantFile? in
                guard let id: String = row["id"],
                      let date: Date = row["date"],
                      let attachmentUrlsJson: String = row["attachmentUrls"],
                      let keys = try? JSONDecoder().decode([String].self, from: Data(attachmentUrlsJson.utf8)),
                      let firstKey = keys.first
                else { return nil }

                let stored = try? StoredRemoteAttachment.fromJSON(firstKey)
                return AssistantFile(
                    id: id,
                    filename: stored?.filename,
                    mimeType: stored?.mimeType,
                    date: date,
                    attachmentKey: firstKey,
                    thumbnailDataBase64: stored?.thumbnailDataBase64
                )
            }
        }
    }

    public func fetchLinks() async throws -> [AssistantLink] {
        try await dbReader.read { [conversationId] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id, m.date, m.linkPreview
                FROM message m
                INNER JOIN memberProfile mp
                    ON mp.inboxId = m.senderId AND mp.conversationId = m.conversationId
                WHERE m.conversationId = ?
                    AND m.contentType = 'linkPreview'
                    AND mp.memberKind IN ('agent', 'agent:convos', 'agent:user-oauth')
                ORDER BY m.date DESC
                """,
                arguments: [conversationId]
            )

            return rows.compactMap { row -> AssistantLink? in
                guard let id: String = row["id"],
                      let date: Date = row["date"],
                      let linkPreviewJson: String = row["linkPreview"],
                      let data = linkPreviewJson.data(using: .utf8),
                      let preview = try? JSONDecoder().decode(LinkPreview.self, from: data)
                else { return nil }
                return AssistantLink(
                    id: id,
                    url: preview.url,
                    title: preview.title,
                    siteName: preview.siteName,
                    imageURL: preview.imageURL,
                    date: date
                )
            }
        }
    }

    public func hasContent() async -> Bool {
        do {
            return try await dbReader.read { [conversationId] db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*)
                    FROM message m
                    INNER JOIN memberProfile mp
                        ON mp.inboxId = m.senderId AND mp.conversationId = m.conversationId
                    WHERE m.conversationId = ?
                        AND m.contentType IN ('attachments', 'linkPreview')
                        AND mp.memberKind IN ('agent', 'agent:convos', 'agent:user-oauth')
                    LIMIT 1
                    """,
                    arguments: [conversationId]
                )
                return (count ?? 0) > 0
            }
        } catch {
            return false
        }
    }
}
