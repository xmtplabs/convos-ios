import Foundation
#if canImport(MediaPlayer) && os(iOS)
@preconcurrency import MediaPlayer
#endif

/// Bridges the iOS system music player's now-playing state into `ConvosConnections`.
///
/// Observes `MPMusicPlayerController.systemMusicPlayer` — fires on track changes and
/// playback state changes while the app is running. Does **not** surface third-party
/// players (Spotify, YouTube Music) — those don't use `MPMusicPlayerController`.
public final class MusicDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .music

    public init() {
        #if canImport(MediaPlayer) && os(iOS)
        self.state = StateBox()
        #endif
    }

    #if canImport(MediaPlayer) && os(iOS)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        Self.map(MPMediaLibrary.authorizationStatus())
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let status: MPMediaLibraryAuthorizationStatus = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return Self.map(status)
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        return [
            AuthorizationDetail(
                identifier: "music",
                displayName: "Apple Music / Media Library",
                status: status,
                note: "Only reflects Apple Music / iTunes playback. Third-party players like Spotify aren't observable through this API."
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        await state.start(emit: emit)
    }

    public func stop() async {
        await state.stop()
    }

    public func snapshotCurrent() async -> MusicPayload {
        await state.snapshotCurrent()
    }

    static func map(_ status: MPMediaLibraryAuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
    }

    static func map(_ state: MPMusicPlaybackState) -> MusicPlaybackState {
        switch state {
        case .stopped: return .stopped
        case .playing: return .playing
        case .paused: return .paused
        case .interrupted: return .interrupted
        case .seekingForward: return .seekingForward
        case .seekingBackward: return .seekingBackward
        @unknown default: return .unknown
        }
    }

    static func buildPayload(from player: MPMusicPlayerController) -> MusicPayload {
        let state = map(player.playbackState)
        if let item = player.nowPlayingItem {
            let now = NowPlayingItem(
                title: item.title,
                artist: item.artist,
                album: item.albumTitle,
                genre: item.genre,
                durationSeconds: item.playbackDuration,
                playbackTimeSeconds: player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0
            )
            let summary = [item.title, item.artist].compactMap { $0 }.joined(separator: " — ")
            return MusicPayload(
                summary: summary.isEmpty ? "Now playing (\(state.rawValue))" : summary,
                nowPlaying: now,
                playbackState: state
            )
        }
        return MusicPayload(
            summary: "Nothing playing",
            nowPlaying: nil,
            playbackState: state
        )
    }

    private actor StateBox {
        private var player: MPMusicPlayerController?
        private var nowPlayingToken: NSObjectProtocol?
        private var stateToken: NSObjectProtocol?
        private var emitter: ConnectionPayloadEmitter?

        func start(emit: @escaping ConnectionPayloadEmitter) async {
            if player != nil { return }
            self.emitter = emit
            let player = MPMusicPlayerController.systemMusicPlayer
            self.player = player
            player.beginGeneratingPlaybackNotifications()

            nowPlayingToken = NotificationCenter.default.addObserver(
                forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                object: player,
                queue: nil
            ) { [weak self] _ in
                Task { [weak self] in await self?.emitCurrent() }
            }
            stateToken = NotificationCenter.default.addObserver(
                forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                object: player,
                queue: nil
            ) { [weak self] _ in
                Task { [weak self] in await self?.emitCurrent() }
            }

            emitCurrent()
        }

        func stop() async {
            player?.endGeneratingPlaybackNotifications()
            if let nowPlayingToken {
                NotificationCenter.default.removeObserver(nowPlayingToken)
            }
            if let stateToken {
                NotificationCenter.default.removeObserver(stateToken)
            }
            nowPlayingToken = nil
            stateToken = nil
            player = nil
            emitter = nil
        }

        func snapshotCurrent() -> MusicPayload {
            let player = player ?? MPMusicPlayerController.systemMusicPlayer
            return MusicDataSource.buildPayload(from: player)
        }

        private func emitCurrent() {
            guard let emitter, let player else { return }
            let payload = MusicDataSource.buildPayload(from: player)
            emitter(ConnectionPayload(source: .music, body: .music(payload)))
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrent() async -> MusicPayload {
        MusicPayload(summary: "Music not available.", nowPlaying: nil, playbackState: .stopped)
    }
    #endif
}
