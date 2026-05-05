import ConvosCore
import SwiftUI

/// Step 1 contact card placeholder. Renders the contact's profile snapshot
/// and a back button. Step 2 will add the "Send a message" CTA, the shared
/// conversations list, and the block / unblock affordance.
struct ContactCardView: View {
    let contact: Contact

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            ContactAvatarPlaceholder(seed: contact.inboxId, initial: monogram)
                .frame(width: 96, height: 96)
                .padding(.top, DesignConstants.Spacing.step6x)

            Text(contact.resolvedDisplayName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)

            if let bio = contact.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
            }

            metadataSection

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var metadataSection: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            HStack {
                Text("Added")
                    .foregroundStyle(.colorTextSecondary)
                Spacer()
                Text(contact.addedAt.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.colorTextPrimary)
            }
        }
        .font(.subheadline)
        .padding(DesignConstants.Spacing.step3x)
    }

    private var monogram: String {
        let trimmed = contact.resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

#Preview {
    NavigationStack {
        ContactCardView(contact: .mock(displayName: "Alice"))
    }
}
