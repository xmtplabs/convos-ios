import ConvosCore
import SwiftUI

struct AssistantJoinStatusView: View {
    let status: AssistantJoinStatus
    var onRetry: (() -> Void)?

    var body: some View {
        switch status {
        case .pending:
            pendingView
        case .noAgentsAvailable:
            errorView(
                icon: "xmark",
                text: "No assistants are available",
                tappable: false
            )
        case .failed:
            errorView(
                icon: "arrow.clockwise",
                text: "Assistant could not join",
                tappable: true
            )
        }
    }

    private var pendingView: some View {
        Text("Assistant is joining…")
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.colorTextTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func errorView(icon: String, text: String, tappable: Bool) -> some View {
        let content = HStack(spacing: DesignConstants.Spacing.stepX) {
            Circle()
                .fill(.colorFillTertiary)
                .frame(width: 16.0, height: 16.0)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }

            Text(text)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.colorTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .center)

        if tappable, let onRetry {
            let action = { onRetry() }
            Button(action: action) {
                content
            }
        } else {
            content
        }
    }
}

#Preview("Pending") {
    AssistantJoinStatusView(status: .pending)
}

#Preview("No Agents") {
    AssistantJoinStatusView(status: .noAgentsAvailable)
}

#Preview("Failed") {
    AssistantJoinStatusView(status: .failed, onRetry: {})
}
