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
    case address
    case phone
    case email
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
    /// The complete source message for automatically indexed useful details.
    /// Presentation layers can show the fact together with the context it came from.
    public let messageText: String?

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
        imageURLString: String?,
        messageText: String? = nil
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
        self.messageText = messageText
    }
}

public final class ContextLibraryRepository: Sendable {
    private static let maximumConversationCount: Int = 500
    private static let maximumItemCount: Int = 500
    private static let maximumTextMessageScanCount: Int = 5_000
    private static let maximumUsefulDetailCount: Int = 250
    private let dbReader: any DatabaseReader

    public init(dbReader: any DatabaseReader) {
        self.dbReader = dbReader
    }

    public func itemsPublisher(conversationIds: [String]) -> AnyPublisher<[ContextLibraryItem], Never> {
        var seenIds: Set<String> = []
        let uniqueIds = Array(conversationIds
            .filter { seenIds.insert($0).inserted }
            .prefix(Self.maximumConversationCount))
        guard !uniqueIds.isEmpty else {
            return Just([]).eraseToAnyPublisher()
        }

        return ValueObservation
            .tracking { db in
                try Self.loadItems(db: db, conversationIds: uniqueIds)
            }
            .publisher(in: dbReader, scheduling: .mainActor)
            .replaceError(with: [])
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    static func loadItems(db: Database, conversationIds: [String]) throws -> [ContextLibraryItem] {
        let placeholders = conversationIds.map { _ in "?" }.joined(separator: ",")
        let mediaRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, conversationId, senderId, date, contentType, attachmentUrls, linkPreview
                FROM message
                WHERE conversationId IN (\(placeholders))
                    AND contentType IN ('attachments', 'linkPreview')
                ORDER BY date DESC
                LIMIT \(maximumItemCount)
                """,
            arguments: StatementArguments(conversationIds)
        )
        let currentInboxId = try DBInbox.currentInboxId(db)

        var items: [ContextLibraryItem] = []
        items.reserveCapacity(min(mediaRows.count + maximumUsefulDetailCount, maximumItemCount))

        for row in mediaRows where items.count < maximumItemCount {
            guard let messageId: String = row["id"],
                  let conversationId: String = row["conversationId"],
                  let senderInboxId: String = row["senderId"],
                  let date: Date = row["date"],
                  let contentType: String = row["contentType"] else {
                continue
            }

            if contentType == MessageContentType.linkPreview.rawValue {
                guard let linkPreviewJSON: String = row["linkPreview"],
                      let data = linkPreviewJSON.data(using: .utf8),
                      let preview = try? JSONDecoder().decode(LinkPreview.self, from: data) else {
                    continue
                }
                items.append(ContextLibraryItem(
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
                ))
                continue
            }

            guard let attachmentURLsJSON: String = row["attachmentUrls"],
                  let data = attachmentURLsJSON.data(using: .utf8),
                  let attachmentKeys = try? JSONDecoder().decode([String].self, from: data) else {
                continue
            }

            let remainingCount = maximumItemCount - items.count
            for (index, key) in attachmentKeys.prefix(remainingCount).enumerated() {
                let descriptor = attachmentDescriptor(for: key)
                items.append(ContextLibraryItem(
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
                ))
            }
        }

        let usefulDetails = try loadUsefulDetails(
            db: db,
            conversationIds: conversationIds,
            placeholders: placeholders,
            currentInboxId: currentInboxId
        )
        return Array((items + usefulDetails)
            .enumerated()
            .sorted {
                if $0.element.date == $1.element.date { return $0.offset < $1.offset }
                return $0.element.date > $1.element.date
            }
            .map(\.element)
            .prefix(maximumItemCount))
    }

    private struct UsefulDetail {
        let kind: ContextLibraryItemKind
        let value: String
    }

    private static func loadUsefulDetails(
        db: Database,
        conversationIds: [String],
        placeholders: String,
        currentInboxId: String?
    ) throws -> [ContextLibraryItem] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, conversationId, senderId, date, text
                FROM message
                WHERE conversationId IN (\(placeholders))
                    AND contentType = 'text'
                    AND text IS NOT NULL
                    AND length(text) BETWEEN 3 AND 4000
                ORDER BY date DESC
                LIMIT \(maximumTextMessageScanCount)
                """,
            arguments: StatementArguments(conversationIds)
        )
        let detectorTypes = NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.link.rawValue
        guard let detector = try? NSDataDetector(types: detectorTypes) else { return [] }

        var items: [ContextLibraryItem] = []
        items.reserveCapacity(min(rows.count, maximumUsefulDetailCount))

        for row in rows where items.count < maximumUsefulDetailCount {
            guard let messageId: String = row["id"],
                  let conversationId: String = row["conversationId"],
                  let senderInboxId: String = row["senderId"],
                  let date: Date = row["date"],
                  let text: String = row["text"],
                  couldContainUsefulDetail(text) else {
                continue
            }

            let details = usefulDetails(in: text, detector: detector)
            let remainingCount = maximumUsefulDetailCount - items.count
            for (index, detail) in details.prefix(remainingCount).enumerated() {
                items.append(ContextLibraryItem(
                    id: "useful-\(detail.kind.rawValue)-\(messageId)-\(index)",
                    kind: detail.kind,
                    title: detail.value,
                    date: date,
                    conversationId: conversationId,
                    senderInboxId: senderInboxId,
                    isMine: senderInboxId == currentInboxId,
                    attachmentKey: nil,
                    filename: nil,
                    mimeType: nil,
                    thumbnailDataBase64: nil,
                    destinationURLString: nil,
                    imageURLString: nil,
                    messageText: String(text.prefix(2_000))
                ))
            }
        }

        return items
    }

    private static func couldContainUsefulDetail(_ text: String) -> Bool {
        if text.contains("@") { return true }
        let digitCount = text.reduce(into: 0) { count, character in
            if character.isNumber { count += 1 }
        }
        if digitCount >= 7 { return true }
        guard digitCount > 0 else { return false }
        let normalized = text.lowercased()
        return [
            " st", " street", " rd", " road", " ave", " avenue", " blvd", " boulevard",
            " ln", " lane", " dr", " drive", " ct", " court", " cir", " circle", " trl",
            " trail", " pkwy", " parkway", " hwy", " highway", " way", " pl", " place",
            " ter", " terrace",
        ].contains { normalized.contains($0) }
    }

    private static func usefulDetails(
        in text: String,
        detector: NSDataDetector
    ) -> [UsefulDetail] {
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        var details: [UsefulDetail] = []

        for match in detector.matches(in: text, options: [], range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let originalValue = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: UsefulDetail?

            switch match.resultType {
            case .address:
                detail = UsefulDetail(kind: .address, value: originalValue)
            case .phoneNumber:
                detail = UsefulDetail(kind: .phone, value: match.phoneNumber ?? originalValue)
            case .link:
                guard match.url?.scheme?.lowercased() == "mailto" else { continue }
                let absoluteString = match.url?.absoluteString ?? originalValue
                let email = String(absoluteString.dropFirst("mailto:".count))
                    .removingPercentEncoding ?? originalValue
                detail = UsefulDetail(kind: .email, value: email)
            default:
                detail = nil
            }

            guard let detail, !detail.value.isEmpty else { continue }
            let deduplicationKey = "\(detail.kind.rawValue):\(detail.value.lowercased())"
            guard seen.insert(deduplicationKey).inserted else { continue }
            details.append(detail)
        }

        return details
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
        case .file, .link, .address, .phone, .email: "Document"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
