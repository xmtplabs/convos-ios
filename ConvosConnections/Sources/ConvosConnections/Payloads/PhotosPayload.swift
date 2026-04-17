import Foundation

/// A summary of the user's photo library, emitted when the library changes.
///
/// Volume control: photo libraries can contain hundreds of thousands of assets. This
/// payload carries counts and a bounded list of recent asset metadata — never pixel data
/// or the full library. Agents interested in specific assets can layer a pull API on top.
public struct PhotosPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let totalAssetCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let screenshotCount: Int
    public let livePhotoCount: Int
    public let recentAssets: [PhotoAssetSummary]
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        totalAssetCount: Int,
        photoCount: Int,
        videoCount: Int,
        screenshotCount: Int,
        livePhotoCount: Int,
        recentAssets: [PhotoAssetSummary],
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.totalAssetCount = totalAssetCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.screenshotCount = screenshotCount
        self.livePhotoCount = livePhotoCount
        self.recentAssets = recentAssets
        self.capturedAt = capturedAt
    }
}

public struct PhotoAssetSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let mediaType: PhotoMediaType
    public let subtype: PhotoMediaSubtype
    public let creationDate: Date?
    public let isFavorite: Bool
    public let latitude: Double?
    public let longitude: Double?

    public init(
        id: String,
        mediaType: PhotoMediaType,
        subtype: PhotoMediaSubtype,
        creationDate: Date?,
        isFavorite: Bool,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.subtype = subtype
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum PhotoMediaType: String, Codable, Sendable {
    case photo
    case video
    case audio
    case unknown
}

public enum PhotoMediaSubtype: String, Codable, Sendable {
    case none
    case screenshot
    case livePhoto = "live_photo"
    case panorama
    case hdr
    case slomo
    case timelapse
    case portrait
}
