import Foundation
import UniformTypeIdentifiers

public enum MediaType: String, Codable, Sendable {
    case image
    case video
    case audio
    case file
    case unknown
}

public struct HydratedAttachment: Hashable, Codable, Sendable {
    public let key: String
    public let isRevealed: Bool
    public let isHiddenByOwner: Bool
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let duration: Double?
    public let thumbnailDataBase64: String?
    public let fileSize: Int?
    public let filename: String?

    public var mediaType: MediaType {
        if let mimeType {
            if mimeType.hasPrefix("image/") { return .image }
            if mimeType.hasPrefix("video/") { return .video }
            if mimeType.hasPrefix("audio/") { return .audio }
            return .file
        }
        if let ext = filenameExtension,
           let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .image) { return .image }
            if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
            if utType.conforms(to: .audio) { return .audio }
            if utType.conforms(to: .data) || utType.conforms(to: .content) { return .file }
        }
        return .image
    }

    public var filenameExtension: String? {
        guard let filename else { return nil }
        let components = filename.split(separator: ".")
        guard components.count > 1, let ext = components.last else { return nil }
        return String(ext).lowercased()
    }

    public var fileTypeLabel: String? {
        if let ext = filenameExtension,
           let utType = UTType(filenameExtension: ext) {
            return utType.localizedDescription
        }
        if let mimeType,
           let utType = UTType(mimeType: mimeType) {
            return utType.localizedDescription
        }
        return nil
    }

    public var aspectRatio: CGFloat? {
        guard let w = width, let h = height, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    public var thumbnailData: Data? {
        guard let thumbnailDataBase64 else { return nil }
        return Data(base64Encoded: thumbnailDataBase64)
    }

    public init(
        key: String,
        isRevealed: Bool = false,
        isHiddenByOwner: Bool = false,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil,
        duration: Double? = nil,
        thumbnailDataBase64: String? = nil,
        fileSize: Int? = nil,
        filename: String? = nil
    ) {
        self.key = key
        self.isRevealed = isRevealed
        self.isHiddenByOwner = isHiddenByOwner
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.duration = duration
        self.thumbnailDataBase64 = thumbnailDataBase64
        self.fileSize = fileSize
        self.filename = filename
    }
}
