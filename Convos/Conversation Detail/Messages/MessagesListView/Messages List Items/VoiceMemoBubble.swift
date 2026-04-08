import ConvosCore
import ConvosCoreiOS
import SwiftUI

extension Notification.Name {
    static let voiceMemoPlaybackRequested: Notification.Name = .init("voiceMemoPlaybackRequested")
}

private let sharedAttachmentLoader: RemoteAttachmentLoader = RemoteAttachmentLoader()

struct VoiceMemoAttachmentView: View {
    let message: AnyMessage
    let attachment: HydratedAttachment
    let bubbleType: MessageBubbleType
    let onReply: (AnyMessage) -> Void

    @State private var player: VoiceMemoPlayer = .shared
    @State private var isLoading: Bool = false

    var body: some View {
        MessageContainer(style: bubbleType, isOutgoing: message.sender.isCurrentUser) {
            VoiceMemoBubbleContent(
                message: message,
                attachment: attachment,
                isOutgoing: message.sender.isCurrentUser,
                player: player,
                isLoading: isLoading
            )
        }
        .messageGesture(
            message: message,
            bubbleStyle: bubbleType,
            onReply: onReply
        )
    }
}

struct VoiceMemoBubbleContent: View {
    /// Shared display width for the voice memo bubble. Used by the inline
    /// transcript row so the two cells visually line up.
    static let bubbleWidth: CGFloat = 220

    let message: AnyMessage
    let attachment: HydratedAttachment
    let isOutgoing: Bool
    let player: VoiceMemoPlayer
    let isLoading: Bool

    @State private var analyzedLevels: [Float]?
    @State private var analyzedDuration: TimeInterval?

    private var displayLevels: [Float] {
        attachment.waveformLevels ?? analyzedLevels ?? Self.placeholderLevels
    }

    /// Best-effort duration for the static (non-playing) state.
    /// Prefers the value the sender encoded into the remote attachment metadata,
    /// falls back to a value we measured locally from the decoded audio file.
    private var staticDuration: TimeInterval {
        attachment.duration ?? analyzedDuration ?? 0
    }

    private var isCurrentlyPlaying: Bool {
        player.currentlyPlayingMessageId == message.messageId
    }

    private var showPause: Bool {
        isCurrentlyPlaying && player.state == .playing
    }

    private var displayDuration: String {
        if isCurrentlyPlaying && player.duration > 0 {
            return formatDuration(player.currentTime)
        }
        return formatDuration(staticDuration)
    }

    private var displayProgress: Double {
        isCurrentlyPlaying ? player.progress : 0
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: showPause ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
            }
            .foregroundStyle(isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary)
            .frame(width: 36, height: 36)
            .background(
                isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.2) : .colorFillMinimal,
                in: Circle()
            )

            VoiceMemoWaveformView(
                levels: displayLevels,
                progress: displayProgress,
                playedColor: isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary,
                unplayedColor: isOutgoing ? .colorTextPrimaryInverted.opacity(0.3) : .colorTextSecondary.opacity(0.3)
            )
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .animation(.linear(duration: 1.0 / 30.0), value: displayProgress)

            Text(displayDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isOutgoing ? .colorTextPrimaryInverted.opacity(0.7) : .colorTextSecondary)
                .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(width: Self.bubbleWidth)
        .task(id: message.messageId) {
            let needsLevels = attachment.waveformLevels == nil && analyzedLevels == nil
            let needsDuration = attachment.duration == nil && analyzedDuration == nil
            guard needsLevels || needsDuration else { return }
            await loadAndCacheAnalysis()
        }
    }

    private func loadAndCacheAnalysis() async {
        do {
            let loaded = try await sharedAttachmentLoader.loadAttachmentData(from: attachment.key)
            let analysis = await VoiceMemoWaveformAnalyzer.analyze(from: loaded.data)
            await MainActor.run {
                if attachment.waveformLevels == nil {
                    analyzedLevels = analysis.levels
                }
                if attachment.duration == nil, analysis.duration > 0 {
                    analyzedDuration = analysis.duration
                }
            }
        } catch {
            Log.error("Failed to analyze voice memo waveform: \(error)")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static let placeholderLevels: [Float] = Array(repeating: Float(0), count: 40)
}

#Preview {
    VStack {
        VoiceMemoBubbleContent(
            message: .message(.mock(), .existing),
            attachment: HydratedAttachment(key: "test", mimeType: "audio/m4a", duration: 7),
            isOutgoing: true,
            player: .shared,
            isLoading: false
        )
        .background(.colorBubble, in: RoundedRectangle(cornerRadius: 16))

        VoiceMemoBubbleContent(
            message: .message(.mock(), .existing),
            attachment: HydratedAttachment(key: "test2", mimeType: "audio/m4a", duration: 15),
            isOutgoing: false,
            player: .shared,
            isLoading: false
        )
        .background(.colorBubbleIncoming, in: RoundedRectangle(cornerRadius: 16))
    }
    .padding()
}
