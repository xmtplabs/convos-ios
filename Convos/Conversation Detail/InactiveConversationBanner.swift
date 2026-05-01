import SwiftUI

struct InactiveConversationBanner: View {
    let onTap: () -> Void

    var body: some View {
        let action = onTap
        Button(action: action) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(.colorLava)
                        .font(.callout)
                    Text("Restored from backup")
                        .font(.callout)
                        .foregroundStyle(.colorTextPrimary)
                }
                Text("You can see and send new messages after another member sends a message")
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restored from backup. You can see and send new messages after another member sends a message.")
        .accessibilityIdentifier("inactive-conversation-banner")
    }
}

#Preview {
    InactiveConversationBanner(onTap: {})
        .padding()
}
