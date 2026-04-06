import ConvosCore
import SwiftUI

struct VoiceMemoReviewView: View {
    let audioURL: URL
    let duration: TimeInterval
    let levels: [Float]
    let onSend: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying: Bool = false
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?
    private var displayLevels: [Float] {
        levels
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 32, height: 32)
                    .background(.colorFillMinimal, in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("voice-memo-play-button")

            VoiceMemoWaveformView(
                levels: displayLevels,
                progress: playbackProgress
            )
            .frame(height: 24)
            .animation(.linear(duration: 1.0 / 30.0), value: playbackProgress)

            Text(formattedDuration(duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.colorTextSecondary)
                .frame(minWidth: 44, alignment: .trailing)

            Button {
                stopPlayback()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.colorTextPrimary, in: Circle())
            }
            .accessibilityLabel("Send voice memo")
            .accessibilityIdentifier("voice-memo-send-button")
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .onDisappear {
            stopPlayback()
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            playbackTimer?.invalidate()
            isPlaying = false
        } else {
            do {
                if player == nil {
                    player = try AVAudioPlayer(contentsOf: audioURL)
                    player?.prepareToPlay()
                }
                if let player {
                    player.currentTime = 0
                    guard player.play() else {
                        Log.error("Failed to play voice memo preview: playback returned false")
                        return
                    }
                }
                isPlaying = true
                startProgressTimer()
            } catch {
                Log.error("Failed to play voice memo preview: \(error)")
            }
        }
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        playbackProgress = 0
    }

    private func startProgressTimer() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [self] _ in
            Task { @MainActor in
                guard let player = self.player else {
                    self.playbackTimer?.invalidate()
                    self.isPlaying = false
                    return
                }
                if player.isPlaying {
                    self.playbackProgress = player.duration > 0 ? player.currentTime / player.duration : 0
                } else {
                    self.playbackTimer?.invalidate()
                    self.isPlaying = false
                    self.playbackProgress = 0
                }
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

import AVFoundation

#Preview {
    let levels: [Float] = (0 ..< 60).map { _ in Float.random(in: 0.05 ... 1.0) }
    VoiceMemoReviewView(
        audioURL: URL(fileURLWithPath: "/tmp/test.m4a"),
        duration: 7,
        levels: levels,
        onSend: {}
    )
    .padding()
}
