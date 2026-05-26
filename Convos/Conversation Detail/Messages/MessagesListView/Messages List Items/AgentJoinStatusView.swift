import ConvosCore
import SwiftUI

struct AgentJoinStatusView: View {
    let status: AgentJoinStatus
    var requesterName: String?
    var onRetry: (() -> Void)?

    var body: some View {
        switch status {
        case .pending:
            pendingView
        case .noAgentsAvailable:
            errorView(
                icon: "xmark",
                text: "No agents are available",
                tappable: false
            )
        case .failed:
            errorView(
                icon: "arrow.clockwise",
                text: "Agent could not join",
                tappable: true
            )
        }
    }

    @State private var isPulsed: Bool = false

    private var pendingView: some View {
        let text = if let requesterName {
            "\(requesterName) invited an agent to join"
        } else {
            "Agent is joining…"
        }
        return Text(text)
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(isPulsed ? .colorTextTertiary : .colorTextSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsed = true
                }
            }
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

#Preview("Pending - Self") {
    AgentJoinStatusView(status: .pending)
}

#Preview("Pending - Other Member") {
    AgentJoinStatusView(status: .pending, requesterName: "Louis")
}

#Preview("No Agents") {
    AgentJoinStatusView(status: .noAgentsAvailable)
}

#Preview("Failed") {
    AgentJoinStatusView(status: .failed, onRetry: {})
}
