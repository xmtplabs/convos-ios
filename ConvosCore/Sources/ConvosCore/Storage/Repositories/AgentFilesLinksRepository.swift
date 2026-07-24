import Combine
import Foundation
import GRDB
import UniformTypeIdentifiers

public struct AgentFile: Sendable, Hashable, Identifiable {
    public let id: String
    public let senderInboxId: String
    public let filename: String?
    public let mimeType: String?
    public let date: Date
    public let attachmentKey: String
    public let thumbnailDataBase64: String?

    /// The sentinel is plumbing, not part of the artifact's name — a file the
    /// group opens should never read `notes~quiet.html`.
    public var displayName: String {
        QuietArtifactUpdate.canonicalFilename(filename) ?? "Untitled"
    }

    public var formattedDate: String {
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
    }
}

public struct AgentLink: Sendable, Hashable, Identifiable {
    public let id: String
    public let senderInboxId: String
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

public final class AgentFilesLinksRepository: Sendable {
    private let dbReader: any DatabaseReader
    private let conversationId: String

    public init(dbReader: any DatabaseReader, conversationId: String) {
        self.dbReader = dbReader
        self.conversationId = conversationId
    }

    public func filesPublisher() -> AnyPublisher<[AgentFile], Never> {
        let conversationId = conversationId
        return ValueObservation
            .tracking { db in
                try Self.loadFiles(db: db, conversationId: conversationId)
            }
            .publisher(in: dbReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    public func linksPublisher() -> AnyPublisher<[AgentLink], Never> {
        let conversationId = conversationId
        return ValueObservation
            .tracking { db in
                try Self.loadLinks(db: db, conversationId: conversationId)
            }
            .publisher(in: dbReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    /// Returns the newest living canvas from a files observation.
    ///
    /// Files normally arrive newest first and are already deduplicated by
    /// canonical filename. Comparing dates here keeps the selection correct
    /// for callers that provide an independently assembled collection.
    public static func canvasFile(in files: [AgentFile]) -> AgentFile? {
        files
            .filter { QuietArtifactUpdate.canonicalFilename($0.filename) == "canvas.html" }
            .max { $0.date < $1.date }
    }

    /// Agent-sent files for a conversation.
    ///
    /// The sender check reads `profile`, the unified per-inbox table, because
    /// that is the only one agent verification writes to. `memberProfile` is
    /// still populated, but only with the kind that arrived on the wire —
    /// plain `agent` — and nothing upgrades it to a verified kind, so a check
    /// against it matches nothing and every agent's files disappear.
    private static func loadFiles(db: Database, conversationId: String) throws -> [AgentFile] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id, m.date, m.attachmentUrls, m.senderId
            FROM message m
            WHERE m.conversationId = ?
                AND m.contentType = 'attachments'
                AND EXISTS (
                    SELECT 1
                    FROM profile p
                    WHERE p.inboxId = m.senderId
                        AND p.memberKind IN ('agent:convos', 'agent:user-oauth')
                )
            ORDER BY m.date DESC
            """,
            arguments: [conversationId]
        )

        let files: [AgentFile] = rows.compactMap { row -> AgentFile? in
            guard let id: String = row["id"],
                  let date: Date = row["date"],
                  let senderInboxId: String = row["senderId"],
                  let attachmentUrlsJson: String = row["attachmentUrls"],
                  let keys = try? JSONDecoder().decode([String].self, from: Data(attachmentUrlsJson.utf8)),
                  let firstKey = keys.first
            else { return nil }

            let parsed = parseAttachmentKey(firstKey)
            return AgentFile(
                id: id,
                senderInboxId: senderInboxId,
                filename: parsed.filename,
                mimeType: parsed.mimeType,
                date: date,
                attachmentKey: firstKey,
                thumbnailDataBase64: parsed.thumbnailDataBase64
            )
        }

        // Rows arrive newest first, so the first occurrence of each filename is the
        // most recent send. Files with no filename pass through individually since
        // we can't tell duplicates apart.
        //
        // Deduping on the canonical name means a quiet update supersedes the
        // loud send it follows: both are the same artifact, and only the newer
        // one survives here even though the transcript ignored the quiet one.
        var seenFilenames: Set<String> = []
        var deduped: [AgentFile] = []
        for file in files {
            if let filename = QuietArtifactUpdate.canonicalFilename(file.filename) {
                if seenFilenames.insert(filename).inserted {
                    deduped.append(file)
                }
            } else {
                deduped.append(file)
            }
        }
        return deduped
    }

    /// Agent-shared links. Same sender check as `loadFiles`, and the same
    /// reason: verification only ever lands on the unified `profile` row.
    private static func loadLinks(db: Database, conversationId: String) throws -> [AgentLink] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id, m.date, m.linkPreview, m.senderId
            FROM message m
            WHERE m.conversationId = ?
                AND m.contentType = 'linkPreview'
                AND EXISTS (
                    SELECT 1
                    FROM profile p
                    WHERE p.inboxId = m.senderId
                        AND p.memberKind IN ('agent:convos', 'agent:user-oauth')
                )
            ORDER BY m.date DESC
            """,
            arguments: [conversationId]
        )

        return rows.compactMap { row -> AgentLink? in
            guard let id: String = row["id"],
                  let date: Date = row["date"],
                  let senderInboxId: String = row["senderId"],
                  let linkPreviewJson: String = row["linkPreview"],
                  let data = linkPreviewJson.data(using: .utf8),
                  let preview = try? JSONDecoder().decode(LinkPreview.self, from: data)
            else { return nil }
            return AgentLink(
                id: id,
                senderInboxId: senderInboxId,
                url: preview.url,
                title: preview.title,
                siteName: preview.siteName,
                imageURL: preview.imageURL,
                date: date
            )
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
            let filename: String
            if let underscoreIndex = name.firstIndex(of: "_") {
                let candidate = String(name[name.index(after: underscoreIndex)...])
                filename = candidate.isEmpty ? name : candidate
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
