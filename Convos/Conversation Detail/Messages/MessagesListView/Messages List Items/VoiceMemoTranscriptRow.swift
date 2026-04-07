import ConvosCore
import SwiftUI

struct VoiceMemoTranscriptRow: View {
    let item: VoiceMemoTranscriptListItem
    var onToggleTranscript: ((String) -> Void)?

    private var canToggle: Bool {
        guard item.status == .completed else { return false }
        guard let text = item.text else { return false }
        return !text.isEmpty
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
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Label(title: { Text(headerText) }, icon: {
                            Image(systemName: "text.bubble")
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
                }
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
    }
    .padding()
}
