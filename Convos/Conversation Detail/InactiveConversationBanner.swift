import SwiftUI

struct InactiveConversationBanner: View {
    enum Variant {
        /// Default: this device just restored its conversations from a
        /// backup, so the local MLS state is rebuilding and waiting for
        /// peer messages to confirm group membership.
        case restoredFromBackup

        /// This device's installation was revoked by another device
        /// running restore. The conversation here is a frozen view —
        /// the only path forward is to reset and re-register (via the
        /// app-level StaleDeviceBanner).
        case deviceReplaced
    }

    let variant: Variant
    let onTap: () -> Void

    private var iconName: String {
        switch variant {
        case .restoredFromBackup: return "cloud.fill"
        case .deviceReplaced: return "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch variant {
        case .restoredFromBackup: return "Restored from backup"
        case .deviceReplaced: return "This device was replaced"
        }
    }

    private var subtitle: String {
        switch variant {
        case .restoredFromBackup:
            return "You can see and send new messages after another member sends a message"
        case .deviceReplaced:
            return "Another device restored this account. New messages won't arrive here. Reset to start fresh."
        }
    }

    var body: some View {
        let action = onTap
        Button(action: action) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(.colorLava)
                        .font(.callout)
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.colorTextPrimary)
                }
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle).")
        .accessibilityIdentifier("inactive-conversation-banner")
    }
}

#Preview("Restored from backup") {
    InactiveConversationBanner(variant: .restoredFromBackup, onTap: {})
        .padding()
}

#Preview("Device replaced") {
    InactiveConversationBanner(variant: .deviceReplaced, onTap: {})
        .padding()
}
