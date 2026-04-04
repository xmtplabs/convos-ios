import Foundation

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
    public let waveformLevels: [Float]?

    public var filenameExtension: String? {
        guard let filename else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    public var fileTypeLabel: String? {
        guard mediaType == .file else { return nil }
        if let ext = filenameExtension {
            return ext.uppercased()
        }
        if let mimeType {
            let components = mimeType.split(separator: "/")
            if components.count == 2 {
                return String(components[1]).uppercased()
            }
        }
        return nil
    }

    public var mediaType: MediaType {
        guard let mimeType else { return .image }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return .file
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
        filename: String? = nil,
        waveformLevels: [Float]? = nil
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
        self.waveformLevels = waveformLevels
    }
}
