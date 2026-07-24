import ConvosCore
import SwiftUI

/// Tappable openers offered while a fresh agent is waiting to be told what it
/// should be. Tapping one sends it as the user's first message, which is the
/// answer the agent's greeting asked for — so the starters double as examples
/// of the kind of answer that works.
///
/// Shown only in a no-builder build, and only before the user has said
/// anything: once they reply, whether by tap or by typing, the agent owns the
/// conversation and a menu of openers would compete with its own follow-ups.
struct ConversationStartersView: View {
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            ForEach(Constant.starters, id: \.self) { starter in
                Button {
                    onSelect(starter)
                } label: {
                    starterRow(starter)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(starter)
                .accessibilityHint("Sends this as your first message")
            }

            // Not a starter — an attachment is something you do, not something
            // you say, so this one tells rather than sends.
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "bolt.fill")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: Constant.iconWidth, alignment: .center)

                Text(Constant.attachmentHint)
                    .font(.callout)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignConstants.Spacing.step4x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(Color.colorFillMinimal)
        )
    }

    private func starterRow(_ starter: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "bubble.fill")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .frame(width: Constant.iconWidth, alignment: .center)

            Text(starter)
                .font(.callout)
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private enum Constant {
        /// Deliberately broad, and one of them deliberately has no task in it:
        /// an agent should be worth starting even when the group doesn't
        /// already know what they want from it.
        static let starters: [String] = [
            "Plan a trip",
            "Help organize our household",
            "No agenda — just hanging out"
        ]
        static let attachmentHint: String =
            "Dump some files or screenshots with context and I'll figure out what to do next"
        static let iconWidth: CGFloat = 16.0
    }
}

#Preview {
    ConversationStartersView(onSelect: { _ in })
        .padding()
}
