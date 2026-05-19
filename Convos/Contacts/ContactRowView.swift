import ConvosCore
import CryptoKit
import Foundation
import SwiftUI

/// Row used in the alphabetical contact list. Visually matches
/// `ContactsPickerRow` (56pt avatar, name + subtitle stacked) so the
/// browser and picker surfaces stay aligned. The trailing accessory is
/// supplied by the caller's context — e.g. a `NavigationLink` chevron in
/// the browse list — so this view stays accessory-agnostic.
struct ContactRowView: View {
    let contact: Contact
    let subtitle: String

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ContactAvatarView(contact: contact)
                .frame(width: 56.0, height: 56.0)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(contact.resolvedDisplayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0.0)
        }
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .contentShape(Rectangle())
        .accessibilityIdentifier("contact-row-\(contact.inboxId)")
    }
}

/// Avatar view for any `Contact`-rendering surface (list row, picker row,
/// contact card header). Uses the shared `AvatarView` path so the contact
/// shares the encrypted-image cache with every other place that renders the
/// same inbox (members list, message bubbles, etc.); a profile update
/// flowing through `mirrorMemberProfileToContactInTransaction` invalidates
/// the cache once and every consumer picks up the new image.
///
/// When the contact has no avatar URL yet (name-only profile event seen so
/// far, or a synthetic contact built from a chat member-tap with no image)
/// the view falls through to the deterministic colored monogram placeholder
/// rather than the standard grey monogram, giving nameless contacts a
/// stable visual identity keyed by `inboxId`.
struct ContactAvatarView: View {
    let contact: Contact

    var body: some View {
        if contact.imageCacheURL != nil {
            AvatarView(
                fallbackName: contact.resolvedDisplayName,
                cacheableObject: contact,
                placeholderImage: nil,
                placeholderImageName: nil,
                agentVerification: contact.agentVerification ?? .unverified
            )
        } else {
            ContactAvatarPlaceholder(seed: contact.inboxId, initial: monogram)
        }
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
        // SHA256 over the UTF-8 bytes is the same
        // deterministic-hash pattern `EmojiSelector` already uses for
        // identifier-derived UI placeholders.
        let hash = SHA256.hash(data: Data(seed.utf8))
        let firstByte = Array(hash)[0]
        let hue = Double(firstByte) / 256.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.7)
    }
}

#Preview {
    VStack(alignment: .leading) {
        ContactRowView(contact: .mock(displayName: "Alice"), subtitle: "Bike Trip 2026")
        ContactRowView(contact: .mock(displayName: "Bob"), subtitle: "DM")
        ContactRowView(contact: .mock(displayName: nil), subtitle: "")
        ContactRowView(
            contact: .mock(displayName: "Convo Assistant", agentVerification: .verified(.convos)),
            subtitle: "Convos Assistant"
        )
        ContactRowView(
            contact: .mock(displayName: "Calendar Bot", agentVerification: .verified(.userOAuth)),
            subtitle: "Verified by Calendar"
        )
    }
    .padding()
}
