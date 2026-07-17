import AVFoundation
import Combine
import Foundation

public enum VoiceMemoRecorderState: Sendable {
    case idle
    case recording
    case recorded(URL, TimeInterval)
}

@MainActor
@Observable
public final class VoiceMemoRecorder: NSObject {
    public var state: VoiceMemoRecorderState = .idle
    public var duration: TimeInterval = 0
    public var audioLevels: [Float] = []

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var durationTimer: Timer?
    private var recordingURL: URL?

    private let maxDuration: TimeInterval = 300

    public override init() {
        super.init()
    }

    /// Resolve mic permission ahead of `startRecording()`. Returns `true`
    /// when the user has already granted (or just granted via the system
    /// prompt) access; `false` when they've denied. Callers must await
    /// this before invoking `startRecording()` - if `record()` is called
    /// while permission is `.undetermined`, AVFoundation succeeds the
    /// initial call but immediately fires
    /// `audioRecorderDidFinishRecording(_:successfully: false)`, which
    /// flips the recorder back to `.idle` without ever capturing audio.
    @MainActor
    public static func ensureRecordPermission() async -> Bool {
        let application = AVAudioApplication.shared
        switch application.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    public func startRecording() throws {
        guard case .idle = state else { return }

        levelTimer?.invalidate()
        durationTimer?.invalidate()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let filename = "voice_memo_\(Int(Date().timeIntervalSince1970)).m4a"
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(filename)
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64000,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            recordingURL = nil
            state = .idle
            return
        }
        audioRecorder = recorder

        duration = 0
        audioLevels = []
        state = .recording

        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleLevel()
            }
        }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
                self.duration = recorder.currentTime
                if self.duration >= self.maxDuration {
                    self.stopRecording()
                }
            }
        }
    }

    public func stopRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil

        guard let recorder = audioRecorder else { return }
        let finalDuration = recorder.currentTime

        if recorder.isRecording {
            recorder.stop()
        }

        if finalDuration < 1.0 {
            cancelRecording()
            return
        }

        if let url = recordingURL {
            duration = finalDuration
            audioRecorder = nil
            state = .recorded(url, finalDuration)
        }
    }

    public func resetState() {
        levelTimer?.invalidate()
        levelTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil

        audioRecorder?.stop()
        audioRecorder = nil
        recordingURL = nil
        duration = 0
        audioLevels = []
        state = .idle
    }

    /// Re-seed a previously recorded memo back into the `.recorded` state.
    /// Used to restore composer state when a send that optimistically cleared
    /// the recorder (e.g. the agent-builder bundle) fails, so the user can
    /// retry from the chat composer. The audio file is left on disk by
    /// `resetState()`, so the original `url` is still valid.
    public func restoreRecorded(url: URL, duration: TimeInterval, audioLevels: [Float]) {
        recordingURL = url
        self.duration = duration
        self.audioLevels = audioLevels
        state = .recorded(url, duration)
    }

    public func cancelRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil

        audioRecorder?.stop()
        audioRecorder = nil

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        duration = 0
        audioLevels = []
        state = .idle
    }

    private func sampleLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = normalizedPower(power)
        audioLevels.append(normalized)
    }

    private func normalizedPower(_ power: Float) -> Float {
        let minDb: Float = -50
        let maxDb: Float = 0
        let clampedPower = max(min(power, maxDb), minDb)
        let normalized = (clampedPower - minDb) / (maxDb - minDb)
        return normalized
    }
}

extension VoiceMemoRecorder: @preconcurrency AVAudioRecorderDelegate {
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag { self.cancelRecording() }
        }
    }

    public func audioRecorderBeginInterruption(_ recorder: AVAudioRecorder) {
        Task { @MainActor in self.stopRecording() }
    }
}
