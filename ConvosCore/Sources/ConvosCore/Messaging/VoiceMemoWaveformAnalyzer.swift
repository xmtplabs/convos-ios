import AVFoundation
import Foundation

public enum VoiceMemoWaveformAnalyzer {
    public struct Analysis: Sendable {
        public let levels: [Float]
        public let duration: TimeInterval

        public init(levels: [Float], duration: TimeInterval) {
            self.levels = levels
            self.duration = duration
        }
    }

    public static func analyzeLevels(from data: Data, sampleCount: Int = 40) async -> [Float] {
        await analyze(from: data, sampleCount: sampleCount).levels
    }

    public static func analyzeLevels(from url: URL, sampleCount: Int = 40) async -> [Float] {
        await analyze(from: url, sampleCount: sampleCount).levels
    }

    public static func analyze(from data: Data, sampleCount: Int = 40) async -> Analysis {
        await Task.detached(priority: .userInitiated) {
            compute(from: data, sampleCount: sampleCount)
        }.value
    }

    public static func analyze(from url: URL, sampleCount: Int = 40) async -> Analysis {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else {
                return placeholderAnalysis(sampleCount: sampleCount)
            }
            return compute(from: data, sampleCount: sampleCount)
        }.value
    }

    private static func compute(from data: Data, sampleCount: Int) -> Analysis {
        guard let audioFile = createAudioFile(from: data) else {
            return placeholderAnalysis(sampleCount: sampleCount)
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration: TimeInterval = sampleRate > 0
            ? Double(audioFile.length) / sampleRate
            : 0

        guard frameCount > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            return Analysis(
                levels: Array(repeating: Float(0.1), count: sampleCount),
                duration: duration
            )
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return Analysis(
                levels: Array(repeating: Float(0.1), count: sampleCount),
                duration: duration
            )
        }

        guard let channelData = buffer.floatChannelData?[0] else {
            return Analysis(
                levels: Array(repeating: Float(0.1), count: sampleCount),
                duration: duration
            )
        }

        let totalSamples = Int(buffer.frameLength)
        let samplesPerBucket = max(totalSamples / sampleCount, 1)
        var levels: [Float] = []

        for i in 0 ..< sampleCount {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, totalSamples)
            guard start < end else {
                levels.append(0.05)
                continue
            }

            var sum: Float = 0
            for j in start ..< end {
                sum += abs(channelData[j])
            }
            let avg = sum / Float(end - start)
            levels.append(max(avg, 0.05))
        }

        let referenceAmplitude: Float = 0.15
        let normalized = levels.map { min($0 / referenceAmplitude, 1.0) }
        return Analysis(levels: normalized, duration: duration)
    }

    private static func placeholderAnalysis(sampleCount: Int) -> Analysis {
        Analysis(
            levels: Array(repeating: Float(0.1), count: sampleCount),
            duration: 0
        )
    }

    private static func createAudioFile(from data: Data) -> AVAudioFile? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform_\(UUID().uuidString).m4a")
        do {
            try data.write(to: tempURL)
            let file = try AVAudioFile(forReading: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            return file
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }
}
