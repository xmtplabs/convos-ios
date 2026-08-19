import Combine
import Foundation
import GRDB
import UniformTypeIdentifiers

public enum ContextLibraryItemKind: String, CaseIterable, Codable, Sendable {
    case photo
    case video
    case link
    case file
    case voice
    case note
}

/// One searchable piece of context already present in the local message store.
/// The repository deliberately returns provenance rather than presentation copy;
/// Your Space resolves conversation and member names from its live models.
public struct ContextLibraryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ContextLibraryItemKind
    public let title: String
    public let date: Date
    public let conversationId: String?
    public let senderInboxId: String?
    public let isMine: Bool
    public let attachmentKey: String?
    public let filename: String?
    public let mimeType: String?
    public let thumbnailDataBase64: String?
    public let destinationURLString: String?
    public let imageURLString: String?

    public init(
        id: String,
        kind: ContextLibraryItemKind,
        title: String,
        date: Date,
        conversationId: String?,
        senderInboxId: String?,
        isMine: Bool,
        attachmentKey: String?,
        filename: String?,
        mimeType: String?,
        thumbnailDataBase64: String?,
        destinationURLString: String?,
        imageURLString: String?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.conversationId = conversationId
        self.senderInboxId = senderInboxId
        self.isMine = isMine
        self.attachmentKey = attachmentKey
        self.filename = filename
        self.mimeType = mimeType
        self.thumbnailDataBase64 = thumbnailDataBase64
        self.destinationURLString = destinationURLString
        self.imageURLString = imageURLString
    }
}

public final class ContextLibraryRepository: Sendable {
    private let dbReader: any DatabaseReader

    public init(dbReader: any DatabaseReader) {
        self.dbReader = dbReader
    }

    public func itemsPublisher(conversationIds: [String]) -> AnyPublisher<[ContextLibraryItem], Never> {
        let uniqueIds = Array(Set(conversationIds))
        guard !uniqueIds.isEmpty else {
            return Just([]).eraseToAnyPublisher()
        }

        return ValueObservation
            .tracking { db in
                try Self.loadItems(db: db, conversationIds: uniqueIds)
            }
            .publisher(in: dbReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    private static func loadItems(db: Database, conversationIds: [String]) throws -> [ContextLibraryItem] {
        let placeholders = conversationIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, conversationId, senderId, date, contentType, attachmentUrls, linkPreview
                FROM message
                WHERE conversationId IN (\(placeholders))
                    AND contentType IN ('attachments', 'linkPreview')
                ORDER BY date DESC
                """,
            arguments: StatementArguments(conversationIds)
        )
        let currentInboxId = try DBInbox.currentInboxId(db)

        return rows.flatMap { row -> [ContextLibraryItem] in
            guard let messageId: String = row["id"],
                  let conversationId: String = row["conversationId"],
                  let senderInboxId: String = row["senderId"],
                  let date: Date = row["date"],
                  let contentType: String = row["contentType"] else {
                return []
            }

            if contentType == MessageContentType.linkPreview.rawValue {
                guard let linkPreviewJSON: String = row["linkPreview"],
                      let data = linkPreviewJSON.data(using: .utf8),
                      let preview = try? JSONDecoder().decode(LinkPreview.self, from: data) else {
                    return []
                }
                return [ContextLibraryItem(
                    id: "link-\(messageId)",
                    kind: .link,
                    title: preview.title ?? URL(string: preview.url)?.host ?? preview.url,
                    date: date,
                    conversationId: conversationId,
                    senderInboxId: senderInboxId,
                    isMine: senderInboxId == currentInboxId,
                    attachmentKey: nil,
                    filename: nil,
                    mimeType: nil,
                    thumbnailDataBase64: nil,
                    destinationURLString: preview.url,
                    imageURLString: preview.imageURL
                )]
            }

            guard let attachmentURLsJSON: String = row["attachmentUrls"],
                  let data = attachmentURLsJSON.data(using: .utf8),
                  let attachmentKeys = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }

            return attachmentKeys.enumerated().map { index, key in
                let descriptor = attachmentDescriptor(for: key)
                return ContextLibraryItem(
                    id: "attachment-\(messageId)-\(index)",
                    kind: kind(filename: descriptor.filename, mimeType: descriptor.mimeType),
                    title: descriptor.filename ?? fallbackTitle(mimeType: descriptor.mimeType),
                    date: date,
                    conversationId: conversationId,
                    senderInboxId: senderInboxId,
                    isMine: senderInboxId == currentInboxId,
                    attachmentKey: key,
                    filename: descriptor.filename,
                    mimeType: descriptor.mimeType,
                    thumbnailDataBase64: descriptor.thumbnailDataBase64,
                    destinationURLString: nil,
                    imageURLString: nil
                )
            }
        }
    }

    private struct AttachmentDescriptor {
        let filename: String?
        let mimeType: String?
        let thumbnailDataBase64: String?
    }

    private static func attachmentDescriptor(for key: String) -> AttachmentDescriptor {
        if let stored = try? StoredRemoteAttachment.fromJSON(key) {
            return AttachmentDescriptor(
                filename: stored.filename,
                mimeType: stored.mimeType ?? inferredMimeType(filename: stored.filename),
                thumbnailDataBase64: stored.thumbnailDataBase64
            )
        }

        if key.hasPrefix("file://") {
            let url = URL(string: key) ?? URL(fileURLWithPath: String(key.dropFirst(7)))
            let storedName = url.lastPathComponent
            let filename: String
            if let underscoreIndex = storedName.firstIndex(of: "_") {
                let candidate = String(storedName[storedName.index(after: underscoreIndex)...])
                filename = candidate.isEmpty ? storedName : candidate
            } else {
                filename = storedName
            }
            return AttachmentDescriptor(
                filename: filename,
                mimeType: inferredMimeType(filename: filename),
                thumbnailDataBase64: nil
            )
        }

        let remoteURL = URL(string: key)
        let filename = remoteURL?.lastPathComponent.nonEmpty
        return AttachmentDescriptor(
            filename: filename,
            mimeType: inferredMimeType(filename: filename),
            thumbnailDataBase64: nil
        )
    }

    private static func inferredMimeType(filename: String?) -> String? {
        guard let filename else { return nil }
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType
    }

    private static func kind(filename: String?, mimeType: String?) -> ContextLibraryItemKind {
        let type: UTType? = filename.flatMap {
            UTType(filenameExtension: ($0 as NSString).pathExtension)
        }
        if type?.conforms(to: .image) == true { return .photo }
        if type?.conforms(to: .movie) == true { return .video }
        if type?.conforms(to: .audio) == true { return .voice }
        if type?.conforms(to: .plainText) == true { return .note }
        if mimeType?.hasPrefix("image/") == true { return .photo }
        if mimeType?.hasPrefix("video/") == true { return .video }
        if mimeType?.hasPrefix("audio/") == true { return .voice }
        if mimeType == "text/plain" { return .note }
        return .file
    }

    private static func fallbackTitle(mimeType: String?) -> String {
        switch kind(filename: nil, mimeType: mimeType) {
        case .photo: "Photo"
        case .video: "Video"
        case .voice: "Voice note"
        case .note: "Note"
        case .file, .link: "Document"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
