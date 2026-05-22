import AVFoundation
import ConvosCore
import SwiftUI

/// Voice-memo chip displayed in the Agent Builder's attachments row
/// once a recording has been captured. Matches the lava-red agent
/// styling of the indicator avatar — same height as the photo/video
/// chips, wider rect to fit the inline play button + waveform.
struct VoiceMemoAttachmentChip: View {
    let url: URL
    let duration: TimeInterval
    let levels: [Float]
    let onRemove: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying: Bool = false
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?
    @State private var isPoofing: Bool = false

    private let chipSize: CGFloat = 80

    var body: some View {
        ZStack(alignment: .topTrailing) {
            chipContent
                .frame(width: chipSize, height: chipSize)
                .background(.colorLava)
                .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))

            removeButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-memo-attachment-chip")
        .scaleEffect(isPoofing ? 1.3 : 1.0)
        .blur(radius: isPoofing ? 12.0 : 0.0)
        .opacity(isPoofing ? 0.0 : 1.0)
        .onDisappear { stopPlayback() }
    }

    private var chipContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(formattedDuration(duration))
                .font(.caption2)
                .foregroundStyle(.white)
                .monospacedDigit()

            Spacer(minLength: 0)

            HStack(spacing: DesignConstants.Spacing.step2x) {
                playPauseButton
                VoiceMemoWaveformView(
                    levels: levels,
                    progress: playbackProgress,
                    playedColor: .white,
                    unplayedColor: .white.opacity(0.4)
                )
                .frame(height: 24)
                .animation(.linear(duration: 1.0 / 30.0), value: playbackProgress)
            }
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
        .onTapGesture { togglePlayback() }
    }

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause voice memo" : "Play voice memo")
        .accessibilityIdentifier("voice-memo-chip-play-button")
    }

    private var removeButton: some View {
        Button {
            triggerRemoval()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10.0, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20.0, height: 20.0)
                .background(.black)
                .clipShape(.circle)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.0))
        }
        .padding(.top, DesignConstants.Spacing.step2x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .accessibilityLabel("Remove voice memo")
        .accessibilityIdentifier("remove-voice-memo-button")
    }

    private func triggerRemoval() {
        stopPlayback()
        withAnimation(.easeOut(duration: 0.2)) {
            isPoofing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onRemove()
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
                    player = try AVAudioPlayer(contentsOf: url)
                    player?.prepareToPlay()
                    player?.currentTime = 0
                }
                guard player?.play() == true else {
                    Log.error("Voice memo chip: playback returned false")
                    return
                }
                isPlaying = true
                startProgressTimer()
            } catch {
                Log.error("Voice memo chip: failed to play: \(error.localizedDescription)")
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
                    self.stopPlayback()
                }
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
