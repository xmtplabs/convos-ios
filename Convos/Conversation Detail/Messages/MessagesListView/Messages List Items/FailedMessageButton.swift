import ConvosCore
import SwiftUI

struct FailedMessageButton: View {
    let message: AnyMessage
    var onRetry: ((AnyMessage) -> Void)?
    var onDelete: ((AnyMessage) -> Void)?

    var body: some View {
        let retryAction: () -> Void = { onRetry?(message) }
        let deleteAction: () -> Void = { onDelete?(message) }
        Menu {
            Button(action: retryAction) {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: deleteAction) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.colorCaution)
                .accessibilityLabel("Message failed to send")
        }
        .accessibilityIdentifier("failed-message-button")
    }
}

#Preview {
    FailedMessageButton(
        message: .message(
            Message.mock(text: "Failed message", sender: .mock(isCurrentUser: true), status: .failed),
            .existing
        ),
        onRetry: { _ in },
        onDelete: { _ in }
    )
}
