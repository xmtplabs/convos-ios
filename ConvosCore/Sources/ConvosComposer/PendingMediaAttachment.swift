#if canImport(UIKit)
import Foundation
import UIKit

public struct PendingFileAttachment: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let filename: String
    public let mimeType: String
    public let fileSize: Int

    public init(id: UUID = UUID(), url: URL, filename: String, mimeType: String, fileSize: Int) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
    }

    /// Mirrors `HydratedAttachment.isHTMLFile` so the composer's staged-file
    /// preview can match the in-chat HTML tile (square thumbnail) instead of
    /// the generic filename + type chip.
    public var isHTMLFile: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            return true
        }
        return mimeType.lowercased() == "text/html"
    }

    public static func == (lhs: PendingFileAttachment, rhs: PendingFileAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

public struct PendingPhotoAttachment: Identifiable, Equatable {
    public let id: UUID
    public let image: UIImage
    public var eagerUploadKey: String?

    public init(id: UUID = UUID(), image: UIImage, eagerUploadKey: String? = nil) {
        self.id = id
        self.image = image
        self.eagerUploadKey = eagerUploadKey
    }

    public static func == (lhs: PendingPhotoAttachment, rhs: PendingPhotoAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

public struct PendingVideoAttachment: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public var thumbnail: UIImage?
    public var eagerUploadKey: String?

    public init(id: UUID = UUID(), url: URL, thumbnail: UIImage? = nil, eagerUploadKey: String? = nil) {
        self.id = id
        self.url = url
        self.thumbnail = thumbnail
        self.eagerUploadKey = eagerUploadKey
    }

    public static func == (lhs: PendingVideoAttachment, rhs: PendingVideoAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

public enum PendingMediaAttachment: Identifiable, Equatable {
    case photo(PendingPhotoAttachment)
    case video(PendingVideoAttachment)
    case file(PendingFileAttachment)

    public var id: UUID {
        switch self {
        case .photo(let p): return p.id
        case .video(let v): return v.id
        case .file(let f): return f.id
        }
    }
}

public let maxPendingMediaAttachments: Int = 8
#endif
