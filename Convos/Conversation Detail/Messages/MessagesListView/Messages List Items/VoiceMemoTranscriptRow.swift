import ConvosCore
import SwiftUI

struct VoiceMemoTranscriptRow: View {
    let item: VoiceMemoTranscriptListItem
    var onToggleTranscript: ((String) -> Void)?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?

    private var canToggle: Bool {
        guard item.status == .completed else { return false }
        guard let text = item.text else { return false }
        return !text.isEmpty
    }

    private var canRetry: Bool {
        item.status == .failed
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
            if item.isOutgoing {
                Spacer(minLength: DesignConstants.Spacing.step12x)
            }

            let toggleAction: () -> Void = {
                guard canToggle else { return }
                onToggleTranscript?(item.parentMessageId)
            }

            Button(action: toggleAction) {
                rowContent
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.colorBackgroundRaisedSecondary)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canToggle)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: item.isExpanded)

            if !item.isOutgoing {
                Spacer(minLength: DesignConstants.Spacing.step12x)
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Label(title: { Text(headerText) }, icon: {
                    Image(systemName: headerIcon)
                })
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)

                if canToggle {
                    Spacer(minLength: DesignConstants.Spacing.stepX)
                    Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            if let text = item.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(item.isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canRetry {
                failureContent
            }
        }
    }

    @ViewBuilder
    private var failureContent: some View {
        if let detail = item.errorDescription, !detail.isEmpty {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        let retryAction: () -> Void = {
            onRetryTranscript?(item)
        }
        Button(action: retryAction) {
            Label(title: { Text("Try again") }, icon: {
                Image(systemName: "arrow.clockwise")
            })
            .font(.caption.weight(.semibold))
            .foregroundStyle(.colorTextPrimary)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .background(
                Capsule().fill(Color.colorFillMinimal)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, DesignConstants.Spacing.stepX)
    }

    private var headerIcon: String {
        switch item.status {
        case .pending: return "waveform"
        case .completed: return "text.bubble"
        case .failed: return "exclamationmark.bubble"
        }
    }

    private var headerText: String {
        switch item.status {
        case .pending: return "Transcribing…"
        case .completed: return "Transcript"
        case .failed: return "Transcript unavailable"
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "1",
                conversationId: "c",
                attachmentKey: "k",
                isOutgoing: false,
                status: .completed,
                text: "Hey, just wanted to check in about lunch tomorrow.",
                isExpanded: false
            )
        )
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "2",
                conversationId: "c",
                attachmentKey: "k",
                isOutgoing: true,
                status: .pending,
                text: nil,
                isExpanded: false
            )
        )
        VoiceMemoTranscriptRow(
            item: VoiceMemoTranscriptListItem(
                parentMessageId: "3",
                conversationId: "c",
                attachmentKey: "k",
                isOutgoing: false,
                status: .failed,
                text: nil,
                errorDescription: "Speech recognition is not authorized",
                isExpanded: false
            )
        )
    }
    .padding()
}
