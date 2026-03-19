import SwiftUI

struct InactiveConversationBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("History restored")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("You can see and send new messages after another member sends a message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("History restored. You can see and send new messages after another member sends a message.")
        .accessibilityIdentifier("inactive-conversation-banner")
    }
}

#Preview {
    InactiveConversationBanner(onTap: {})
        .padding()
}
