import Foundation
import GRDB
import UniformTypeIdentifiers

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

                let parsed = Self.parseAttachmentKey(firstKey)
                return AssistantFile(
                    id: id,
                    filename: parsed.filename,
                    mimeType: parsed.mimeType,
                    date: date,
                    attachmentKey: firstKey,
                    thumbnailDataBase64: parsed.thumbnailDataBase64
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

    private struct ParsedAttachment {
        let filename: String?
        let mimeType: String?
        let thumbnailDataBase64: String?
    }

    private static func parseAttachmentKey(_ key: String) -> ParsedAttachment {
        if let stored = try? StoredRemoteAttachment.fromJSON(key) {
            return ParsedAttachment(
                filename: stored.filename,
                mimeType: stored.mimeType,
                thumbnailDataBase64: stored.thumbnailDataBase64
            )
        }

        if key.hasPrefix("file://") {
            let url = URL(string: key) ?? URL(fileURLWithPath: String(key.dropFirst(7)))
            let name = url.lastPathComponent
            var filename: String
            if let underscoreIndex = name.firstIndex(of: "_") {
                filename = String(name[name.index(after: underscoreIndex)...])
            } else {
                filename = name
            }
            var mimeType: String?
            let ext = (filename as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                mimeType = utType.preferredMIMEType
            }
            return ParsedAttachment(filename: filename, mimeType: mimeType, thumbnailDataBase64: nil)
        }

        return ParsedAttachment(filename: nil, mimeType: nil, thumbnailDataBase64: nil)
    }
}
