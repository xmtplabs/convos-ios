import ConvosCore
import SwiftUI

/// Compact row used in the alphabetical contact list. Step 1 ships with a
/// monogram-only placeholder avatar; the full image-loading avatar is wired
/// up in Step 2 alongside the contact card.
struct ContactRowView: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ContactAvatarPlaceholder(seed: contact.inboxId, initial: monogram)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2.0) {
                Text(contact.resolvedDisplayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2.0)
        .accessibilityIdentifier("contact-row-\(contact.inboxId)")
    }

    private var monogram: String {
        let trimmed = contact.resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

struct ContactAvatarPlaceholder: View {
    let seed: String
    let initial: String

    var body: some View {
        Circle()
            .fill(backgroundColor)
            .overlay {
                Text(initial)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            }
    }

    private var backgroundColor: Color {
        let hue = Double(abs(seed.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.7)
    }
}

#Preview {
    VStack(alignment: .leading) {
        ContactRowView(contact: .mock(displayName: "Alice"))
        ContactRowView(contact: .mock(displayName: "Bob"))
        ContactRowView(contact: .mock(displayName: nil))
    }
    .padding()
}
