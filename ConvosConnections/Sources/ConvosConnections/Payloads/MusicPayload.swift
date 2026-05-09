import Foundation

/// Now-playing snapshot captured by `MusicDataSource` on track changes and playback state
/// changes in the iOS system music player.
///
/// Only reflects Apple Music / iTunes playback — third-party players (Spotify, YouTube
/// Music, etc.) do not surface through `MPMusicPlayerController`.
public struct MusicPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let nowPlaying: NowPlayingItem?
    public let playbackState: MusicPlaybackState
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        nowPlaying: NowPlayingItem?,
        playbackState: MusicPlaybackState,
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.nowPlaying = nowPlaying
        self.playbackState = playbackState
        self.capturedAt = capturedAt
    }
}

public struct NowPlayingItem: Codable, Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let genre: String?
    public let durationSeconds: Double
    public let playbackTimeSeconds: Double

    public init(
        title: String?,
        artist: String?,
        album: String?,
        genre: String?,
        durationSeconds: Double,
        playbackTimeSeconds: Double
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.durationSeconds = durationSeconds
        self.playbackTimeSeconds = playbackTimeSeconds
    }
}

public enum MusicPlaybackState: String, Codable, Sendable {
    case stopped
    case playing
    case paused
    case interrupted
    case seekingForward = "seeking_forward"
    case seekingBackward = "seeking_backward"
    case unknown
}
