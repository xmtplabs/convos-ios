import AVFoundation
import Foundation

public enum VoiceMemoPlaybackState: Sendable {
    case idle
    case loading
    case playing
    case paused
}

@MainActor
@Observable
public final class VoiceMemoPlayer: NSObject {
    public static let shared: VoiceMemoPlayer = VoiceMemoPlayer()

    public var state: VoiceMemoPlaybackState = .idle
    public var currentTime: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var progress: Double = 0
    public var currentlyPlayingMessageId: String?

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() {
        super.init()
    }

    public func play(data: Data, messageId: String) throws {
        stop()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()

        audioPlayer = player
        duration = player.duration
        currentTime = 0
        progress = 0
        currentlyPlayingMessageId = messageId

        guard player.play() else {
            stop()
            return
        }
        state = .playing

        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
    }

    public func pause() {
        audioPlayer?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        state = .paused
    }

    public func resume() {
        guard audioPlayer != nil else { return }
        audioPlayer?.play()
        state = .playing
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
    }

    public func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        state = .idle
        currentTime = 0
        progress = 0
        currentlyPlayingMessageId = nil
    }

    public func togglePlayback(data: Data, messageId: String) throws {
        if currentlyPlayingMessageId == messageId {
            switch state {
            case .playing:
                pause()
            case .paused:
                resume()
            default:
                try play(data: data, messageId: messageId)
            }
        } else {
            try play(data: data, messageId: messageId)
        }
    }

    private func updateProgress() {
        guard let player = audioPlayer else { return }
        currentTime = player.currentTime
        duration = player.duration
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }
}

extension VoiceMemoPlayer: @preconcurrency AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    public func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        Task { @MainActor in self.pause() }
    }
}
