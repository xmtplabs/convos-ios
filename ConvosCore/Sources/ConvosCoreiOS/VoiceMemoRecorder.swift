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
