import AVFoundation
import Foundation

public enum VoiceMemoWaveformAnalyzer {
    public static func analyzeLevels(from data: Data, sampleCount: Int = 40) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            computeLevels(from: data, sampleCount: sampleCount)
        }.value
    }

    public static func analyzeLevels(from url: URL, sampleCount: Int = 40) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else {
                return Array(repeating: Float(0.1), count: sampleCount)
            }
            return computeLevels(from: data, sampleCount: sampleCount)
        }.value
    }

    private static func computeLevels(from data: Data, sampleCount: Int) -> [Float] {
        guard let audioFile = createAudioFile(from: data) else {
            return Array(repeating: Float(0.1), count: sampleCount)
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            return Array(repeating: Float(0.1), count: sampleCount)
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return Array(repeating: Float(0.1), count: sampleCount)
        }

        guard let channelData = buffer.floatChannelData?[0] else {
            return Array(repeating: Float(0.1), count: sampleCount)
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
        return levels.map { min($0 / referenceAmplitude, 1.0) }
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
