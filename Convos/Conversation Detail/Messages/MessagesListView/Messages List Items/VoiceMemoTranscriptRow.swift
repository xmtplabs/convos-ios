import ConvosCore
import SwiftUI

struct VoiceMemoTranscriptRow: View {
    let item: VoiceMemoTranscriptListItem

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
            if item.isOutgoing {
                Spacer(minLength: DesignConstants.Spacing.step12x)
            }

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Label(title: { Text(headerText) }, icon: {
                    Image(systemName: "text.bubble")
                })
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)

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
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.colorBackgroundRaisedSecondary)
            )

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
