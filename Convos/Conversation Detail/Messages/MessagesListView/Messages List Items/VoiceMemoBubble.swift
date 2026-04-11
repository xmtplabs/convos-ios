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
    var transcript: VoiceMemoTranscriptListItem?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?

    @State private var player: VoiceMemoPlayer = .shared
    @State private var isLoading: Bool = false

    var body: some View {
        MessageContainer(style: bubbleType, isOutgoing: message.sender.isCurrentUser) {
            VoiceMemoBubbleContent(
                message: message,
                attachment: attachment,
                isOutgoing: message.sender.isCurrentUser,
                player: player,
                isLoading: isLoading,
                transcript: transcript,
                onRetryTranscript: onRetryTranscript
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
    static let bubbleWidth: CGFloat = 280

    let message: AnyMessage
    let attachment: HydratedAttachment
    let isOutgoing: Bool
    let player: VoiceMemoPlayer
    let isLoading: Bool
    var transcript: VoiceMemoTranscriptListItem?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?

    @State private var analyzedLevels: [Float]?
    @State private var analyzedDuration: TimeInterval?
    @State private var isSheetPresented: Bool = false
    @State private var optimisticPending: Bool = false
    @State private var isTruncated: Bool = false

    private var displayLevels: [Float] {
        attachment.waveformLevels ?? analyzedLevels ?? Self.placeholderLevels
    }

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

    private var transcriptStatus: VoiceMemoTranscriptStatus {
        guard let transcript else { return .permanentlyFailed }
        if optimisticPending,
           transcript.status == .notRequested || transcript.status == .pending {
            return .pending
        }
        return transcript.status
    }

    var body: some View {
        VStack(spacing: 0) {
            audioPlayerRow
            transcriptSection
        }
        .frame(width: Self.bubbleWidth)
        .task(id: message.messageId) {
            let needsLevels = attachment.waveformLevels == nil && analyzedLevels == nil
            let needsDuration = attachment.duration == nil && analyzedDuration == nil
            guard needsLevels || needsDuration else { return }
            await loadAndCacheAnalysis()
        }
        .onChange(of: transcript?.status) { _, newStatus in
            if newStatus == .completed || newStatus == .failed {
                optimisticPending = false
            }
        }
        .sheet(isPresented: $isSheetPresented) {
            if let transcript {
                VoiceMemoTranscriptSheet(item: transcript)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
            }
        }
    }

    private var audioPlayerRow: some View {
        HStack(spacing: 0) {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: showPause ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                }
            }
            .foregroundStyle(isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary)
            .frame(width: 32, height: 32)
            .background(
                isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.2) : .colorFillSubtle,
                in: Circle()
            )
            .frame(width: 48, height: 48)

            HStack(spacing: DesignConstants.Spacing.step2x) {
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
                    .font(.caption)
                    .foregroundStyle(isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.6) : .colorTextSecondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .padding(.trailing, DesignConstants.Spacing.step4x)
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        switch transcriptStatus {
        case .completed:
            if let text = transcript?.text, !text.isEmpty {
                let tapAction = { if isTruncated { isSheetPresented = true } }
                Button(action: tapAction) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.6) : .colorTextSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Text(text)
                                    .font(.caption)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .overlay(GeometryReader { fullProxy in
                                        GeometryReader { _ in
                                            Color.clear.preference(
                                                key: FullTextHeightKey.self,
                                                value: fullProxy.size.height
                                            )
                                        }
                                    })
                            )
                            .onPreferenceChange(FullTextHeightKey.self) { fullHeight in
                                guard let fullHeight else { return }
                                let lineHeight = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
                                isTruncated = fullHeight > lineHeight * 3.5
                            }

                        if isTruncated {
                            Image(systemName: "chevron.right")
                                .font(.subheadline)
                                .foregroundStyle(isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.3) : .colorTextTertiary)
                        }
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.bottom, DesignConstants.Spacing.step3x)
                }
                .buttonStyle(.plain)
                .background(GesturePassthroughBackground())
            }

        case .notRequested:
            if let transcript {
                let tapAction = {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        optimisticPending = true
                    }
                    onRetryTranscript?(transcript)
                }
                Button(action: tapAction) {
                    Text("View transcript")
                        .font(.footnote)
                        .foregroundStyle(isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.2) : .colorFillSubtle,
                            in: .rect(cornerRadius: 24)
                        )
                }
                .buttonStyle(.plain)
                .background(GesturePassthroughBackground())
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.bottom, DesignConstants.Spacing.step2x)
            }

        case .pending:
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(isOutgoing ? .colorTextPrimaryInverted : .colorTextSecondary)
                Text("Transcribing\u{2026}")
                    .font(.caption)
                    .foregroundStyle(isOutgoing ? Color.colorTextPrimaryInverted.opacity(0.6) : .colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.bottom, DesignConstants.Spacing.step3x)

        case .failed, .permanentlyFailed:
            EmptyView()
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
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static let placeholderLevels: [Float] = Array(repeating: Float(0), count: 40)

    private enum FullTextHeightKey: PreferenceKey {
        static let defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            value = value ?? nextValue()
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        VoiceMemoBubbleContent(
            message: .message(.mock(), .existing),
            attachment: HydratedAttachment(key: "test", mimeType: "audio/m4a", duration: 7),
            isOutgoing: true,
            player: .shared,
            isLoading: false
        )
        .background(.colorBubble, in: RoundedRectangle(cornerRadius: 24))

        VoiceMemoBubbleContent(
            message: .message(.mock(), .existing),
            attachment: HydratedAttachment(key: "test2", mimeType: "audio/m4a", duration: 15),
            isOutgoing: true,
            player: .shared,
            isLoading: false,
            transcript: VoiceMemoTranscriptListItem(
                parentMessageId: "1",
                conversationId: "c",
                attachmentKey: "k",
                senderDisplayName: "Alice",
                isOutgoing: true,
                status: .completed,
                text: "Blame it all on my roots, I showed up in boots, And ruined your black tie affair. The last one to know, the last one to show."
            )
        )
        .background(.colorBubble, in: RoundedRectangle(cornerRadius: 24))

        VoiceMemoBubbleContent(
            message: .message(.mock(), .existing),
            attachment: HydratedAttachment(key: "test3", mimeType: "audio/m4a", duration: 18),
            isOutgoing: true,
            player: .shared,
            isLoading: false,
            transcript: VoiceMemoTranscriptListItem(
                parentMessageId: "2",
                conversationId: "c",
                attachmentKey: "k",
                senderDisplayName: "Alice",
                isOutgoing: true,
                status: .notRequested,
                text: nil
            )
        )
        .background(.colorBubble, in: RoundedRectangle(cornerRadius: 24))
    }
    .padding()
}
