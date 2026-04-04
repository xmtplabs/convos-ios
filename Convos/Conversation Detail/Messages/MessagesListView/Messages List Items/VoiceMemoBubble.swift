import ConvosCore
import SwiftUI

extension Notification.Name {
    static let voiceMemoPlaybackRequested: Notification.Name = .init("voiceMemoPlaybackRequested")
}

struct VoiceMemoAttachmentView: View {
    let message: AnyMessage
    let attachment: HydratedAttachment
    let bubbleType: MessageBubbleType
    let onReply: (AnyMessage) -> Void

    @State private var player: VoiceMemoPlayer = .shared
    @State private var audioData: Data?
    @State private var isLoading: Bool = false
    @State private var playTrigger: Int = 0

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
            onSingleTap: { playTrigger += 1 },
            onReply: onReply
        )
        .onChange(of: playTrigger) {
            Task { await togglePlayback() }
        }
    }

    private func togglePlayback() async {
        if let data = audioData {
            do {
                try player.togglePlayback(data: data, messageId: message.messageId)
            } catch {
                Log.error("Failed to play voice memo: \(error)")
            }
            return
        }

        guard !isLoading else { return }
        isLoading = true
        do {
            let loader = RemoteAttachmentLoader()
            let loaded = try await loader.loadAttachmentData(from: attachment.key)
            audioData = loaded.data
            try await MainActor.run {
                try player.play(data: loaded.data, messageId: message.messageId)
            }
        } catch {
            Log.error("Failed to load voice memo: \(error)")
        }
        isLoading = false
    }
}

struct VoiceMemoBubbleContent: View {
    let message: AnyMessage
    let attachment: HydratedAttachment
    let isOutgoing: Bool
    let player: VoiceMemoPlayer
    let isLoading: Bool

    @State private var analyzedLevels: [Float]?

    private var displayLevels: [Float] {
        attachment.waveformLevels ?? analyzedLevels ?? Self.placeholderLevels
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
        return formatDuration(attachment.duration ?? 0)
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
            .foregroundStyle(isOutgoing ? .white : .colorTextPrimary)
            .frame(width: 36, height: 36)
            .background(
                isOutgoing ? Color.white.opacity(0.2) : .colorFillMinimal,
                in: Circle()
            )

            VoiceMemoWaveformView(
                levels: displayLevels,
                progress: displayProgress,
                playedColor: isOutgoing ? .white : .colorTextPrimary,
                unplayedColor: isOutgoing ? .white.opacity(0.3) : .colorTextSecondary.opacity(0.3)
            )
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .animation(.linear(duration: 1.0 / 30.0), value: displayProgress)

            Text(displayDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isOutgoing ? .white.opacity(0.7) : .colorTextSecondary)
                .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(width: 220)
        .task(id: message.messageId) {
            guard attachment.waveformLevels == nil, analyzedLevels == nil else { return }
            await loadAndCacheWaveform()
        }
    }

    private func loadAndCacheWaveform() async {
        do {
            let loader = RemoteAttachmentLoader()
            let loaded = try await loader.loadAttachmentData(from: attachment.key)
            let levels = await VoiceMemoWaveformAnalyzer.analyzeLevels(from: loaded.data)
            await MainActor.run { analyzedLevels = levels }
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
