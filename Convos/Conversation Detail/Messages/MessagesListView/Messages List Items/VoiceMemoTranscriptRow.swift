import ConvosCore
import SwiftUI

struct VoiceMemoTranscriptRow: View {
    let item: VoiceMemoTranscriptListItem
    var isTailed: Bool = false
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?

    @State private var isSheetPresented: Bool = false

    private static let cornerRadius: CGFloat = 16
    private static let tailRadius: CGFloat = 4

    /// Set when the user taps the action capsule, until the publisher reports a
    /// non-`.notRequested` status. Lets the row show "Transcribing\u{2026}" instantly
    /// without waiting for the GRDB observation to make a round trip through the
    /// transcription pipeline. Without this, on a fast device the row can flip
    /// straight from "Tap to transcribe" to the completed transcript.
    @State private var optimisticPending: Bool = false

    /// The status the row should display, taking the optimistic flag into account.
    private var displayStatus: VoiceMemoTranscriptStatus {
        if optimisticPending,
           item.status == .notRequested || item.status == .pending {
            return .pending
        }
        return item.status
    }

    private var canPresentSheet: Bool {
        guard displayStatus == .completed else { return false }
        guard let text = item.text else { return false }
        return !text.isEmpty
    }

    private var canRequestTranscription: Bool {
        displayStatus == .notRequested || displayStatus == .failed
    }

    private var isInteractive: Bool {
        canPresentSheet || canRequestTranscription
    }

    private var showsTrailingChevron: Bool {
        canPresentSheet
    }

    var body: some View {
        let primaryAction: () -> Void = {
            if canPresentSheet {
                isSheetPresented = true
            } else if canRequestTranscription {
                withAnimation(.easeInOut(duration: 0.2)) {
                    optimisticPending = true
                }
                onRetryTranscript?(item)
            }
        }

        Button(action: primaryAction) {
            rowContent
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .background(
                    bubbleShape
                        .fill(Color.colorBackgroundRaisedSecondary)
                )
                .contentShape(bubbleShape)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .animation(.easeInOut(duration: 0.2), value: displayStatus)
        .onChange(of: item.status) { _, newStatus in
            // Once the publisher catches up and reports a real terminal state,
            // drop the optimistic flag so the row reflects truth again.
            if newStatus == .completed || newStatus == .failed {
                optimisticPending = false
            }
        }
        .sheet(isPresented: $isSheetPresented) {
            VoiceMemoTranscriptSheet(item: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                if showsHeaderLabel {
                    Label(title: { Text(headerText) }, icon: {
                        Image(systemName: headerIcon)
                    })
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
                }

                if displayStatus == .pending {
                    pendingBody
                }

                if let text = item.text, !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if displayStatus == .failed {
                    failureBody
                }

                if displayStatus == .notRequested {
                    capsuleAffordance(title: "Tap to transcribe", systemImage: "text.bubble")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsTrailingChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .frame(width: VoiceMemoBubbleContent.bubbleWidth, alignment: .leading)
    }

    /// The bubble shape mirrors `MessageContainer.mask` for incoming messages so the
    /// transcript row can take over the avatar tail when it sits at the bottom of a
    /// group below a voice memo bubble. Transcripts are only shown for incoming voice
    /// memos, so we never need an outgoing-tail variant.
    private var bubbleShape: UnevenRoundedRectangle {
        let bottomLeading: CGFloat = isTailed ? Self.tailRadius : Self.cornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: Self.cornerRadius,
            bottomLeadingRadius: bottomLeading,
            bottomTrailingRadius: Self.cornerRadius,
            topTrailingRadius: Self.cornerRadius,
            style: .continuous
        )
    }

    /// The small inline header label is hidden for states that already render their
    /// own primary content (the call-to-action capsules and the pending spinner).
    private var showsHeaderLabel: Bool {
        switch displayStatus {
        case .notRequested, .failed, .pending:
            return false
        case .completed:
            return true
        }
    }

    @ViewBuilder
    private var pendingBody: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
            Text("Transcribing\u{2026}")
                .font(.callout)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    @ViewBuilder
    private var failureBody: some View {
        if let detail = item.errorDescription, !detail.isEmpty {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        capsuleAffordance(title: "Tap to try again", systemImage: "arrow.clockwise")
    }

    @ViewBuilder
    private func capsuleAffordance(title: String, systemImage: String) -> some View {
        Label(title: { Text(title) }, icon: {
            Image(systemName: systemImage)
        })
        .font(.callout.weight(.semibold))
        .foregroundStyle(.colorTextPrimary)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(
            Capsule().fill(Color.colorFillMinimal)
        )
    }

    private var headerIcon: String {
        switch displayStatus {
        case .notRequested: return "text.bubble"
        case .pending: return "waveform"
        case .completed: return "text.bubble"
        case .failed: return "exclamationmark.bubble"
        }
    }

    private var headerText: String {
        switch displayStatus {
        case .notRequested: return "Tap to transcribe"
        case .pending: return "Transcribing…"
        case .completed: return "Transcript"
        case .failed: return "Transcript unavailable"
        }
    }
}

private struct VoiceMemoTranscriptSheet: View {
    let item: VoiceMemoTranscriptListItem

    @Environment(\.dismiss) private var dismiss: DismissAction

    private var title: String {
        item.senderDisplayName ?? "Transcript"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    if let text = item.text, !text.isEmpty {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(.colorTextPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text("Transcript unavailable")
                            .font(.body)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignConstants.Spacing.step4x)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "0",
                conversationId: "c",
                attachmentKey: "k",
                senderDisplayName: "Alice",
                isOutgoing: false,
                status: .notRequested,
                text: nil
            )
        )
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "1",
                conversationId: "c",
                attachmentKey: "k",
                senderDisplayName: "Alice",
                isOutgoing: false,
                status: .completed,
                text: "Hey, just wanted to check in about lunch tomorrow."
            )
        )
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "2",
                conversationId: "c",
                attachmentKey: "k",
                senderDisplayName: "Alice",
                isOutgoing: false,
                status: .pending,
                text: nil
            )
        )
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "3",
                conversationId: "c",
                attachmentKey: "k",
                senderDisplayName: "Alice",
                isOutgoing: false,
                status: .failed,
                text: nil,
                errorDescription: "Speech recognition is not authorized"
            )
        )
    }
    .padding()
}
