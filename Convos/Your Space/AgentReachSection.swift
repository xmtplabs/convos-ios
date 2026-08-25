import ConvosComposer
import SwiftUI

/// Which way of reaching an agent a row is showing.
///
/// One row view parameterized by the channel it draws, rather than a near-copy
/// per channel. Mirrors the pattern `ContactCardMode` uses elsewhere.
enum AgentReachChannel {
    case text
    case email

    /// The caption under the value. Both name the action, not the medium, so
    /// the two rows read as a pair.
    var caption: String {
        switch self {
        case .text: return "Text"
        case .email: return "Email"
        }
    }

    /// The glyph in the row's badge, standing in for the app that owns the
    /// channel the way the Space page uses the platform's own icons.
    var symbolName: String {
        switch self {
        case .text: return "message.fill"
        case .email: return "envelope.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .text: return .colorGreen
        case .email: return .colorBlue
        }
    }

    /// The scheme that reaches this channel from the value.
    var urlScheme: String {
        switch self {
        case .text: return "sms:"
        case .email: return "mailto:"
        }
    }

    var identifierStem: String {
        switch self {
        case .text: return "agent-reach-text"
        case .email: return "agent-reach-email"
        }
    }

    var copyAccessibilityLabel: String {
        switch self {
        case .text: return "Copy phone number"
        case .email: return "Copy email address"
        }
    }

    func openAccessibilityLabel(agentName: String, value: String) -> String {
        switch self {
        case .text: return "Text \(agentName) at \(value)"
        case .email: return "Email \(agentName) at \(value)"
        }
    }
}

/// How to reach one agent from outside Convos.
///
/// Ported from the Space template's Add from Anywhere page: the channels, then
/// worked examples of what each kind of message does. The examples carry the
/// part a bare address cannot teach -- that mailing the agent updates the
/// group -- in a member's own words rather than as instructions.
///
/// A channel the runtime has not provisioned is absent rather than drawn
/// empty, and the caller omits the section when there is neither: an address
/// that receives nothing is worse than no row.
struct AgentReachSection: View {
    let agentName: String
    let phone: String?
    let email: String?

    /// True when there is at least one channel to draw. The call site checks
    /// this rather than nesting the whole section in an `if`.
    var hasAnyChannel: Bool {
        phone != nil || email != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            header
            channels
            examples
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Add from Anywhere")
                .font(.title3.weight(.bold))
                .foregroundStyle(.colorTextPrimary)
            Text("\(agentName) comes with its own number and address. Send it a message from any app and it updates the group, then says what changed.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    @ViewBuilder
    private var channels: some View {
        VStack(spacing: 0.0) {
            if let phone {
                AgentReachChannelRow(channel: .text, value: phone, agentName: agentName)
            }
            if phone != nil, email != nil {
                Divider().padding(.leading, Constant.separatorInset)
            }
            if let email {
                AgentReachChannelRow(channel: .email, value: email, agentName: agentName)
            }
        }
        .background(
            .colorBackgroundRaisedSecondary,
            in: .rect(cornerRadius: DesignConstants.CornerRadius.medium)
        )
    }

    private var examples: some View {
        VStack(spacing: 0.0) {
            AgentReachExampleRow(
                message: "Here is my flight confirmation. All booked",
                outcome: "Updates Notes"
            )
            Divider().padding(.leading, DesignConstants.Spacing.step4x)
            AgentReachExampleRow(
                message: "We changed the reservation to 8. Update the group",
                outcome: "Updates Events"
            )
            Divider().padding(.leading, DesignConstants.Spacing.step4x)
            AgentReachExampleRow(
                message: "Can you text me the wifi for the office?",
                outcome: "Replies to you directly"
            )
        }
        .background(
            .colorBackgroundRaisedSecondary,
            in: .rect(cornerRadius: DesignConstants.CornerRadius.medium)
        )
    }

    private enum Constant {
        /// Aligns a separator with the value column rather than the badge, so
        /// the badges read as one stack.
        static let separatorInset: CGFloat = 62.0
    }
}

/// One channel: a badge, the address, and a control that copies it.
private struct AgentReachChannelRow: View {
    let channel: AgentReachChannel
    let value: String
    let agentName: String

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            reachButton
            AgentReachCopyButton(
                value: value,
                accessibilityLabel: channel.copyAccessibilityLabel,
                identifier: "\(channel.identifierStem)-copy"
            )
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    private var reachButton: some View {
        let openLabel: String = channel.openAccessibilityLabel(agentName: agentName, value: value)
        let action = { open() }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                AgentReachBadge(symbolName: channel.symbolName, tint: channel.badgeColor)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(channel.caption)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer(minLength: 0.0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(openLabel)
        .accessibilityIdentifier(channel.identifierStem)
    }

    /// `sms:` rejects the spaces and punctuation a number is displayed with, so
    /// the scheme gets the dialable form while the row keeps the readable one.
    /// A value the initializer still refuses opens nothing.
    private var schemeValue: String {
        switch channel {
        case .email:
            return value
        case .text:
            return value.filter { $0.isNumber || $0 == "+" }
        }
    }

    private func open() {
        guard let url = URL(string: "\(channel.urlScheme)\(schemeValue)") else { return }
        openURL(url)
    }
}

/// The channel's glyph on a tinted rounded square, in the shape of an app icon.
private struct AgentReachBadge: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        Image(systemName: symbolName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(width: Constant.size, height: Constant.size)
            .background(tint, in: .rect(cornerRadius: Constant.cornerRadius))
    }

    private enum Constant {
        static let size: CGFloat = 34.0
        static let cornerRadius: CGFloat = 9.0
    }
}

/// Copies one address and confirms in place.
///
/// Copying is the point of the row for anyone not holding this phone: a number
/// read off a screen and retyped is where a digit goes missing. It confirms in
/// the row rather than with a toast, because the row is the thing that changed.
private struct AgentReachCopyButton: View {
    let value: String
    let accessibilityLabel: String
    let identifier: String

    @State private var didCopy: Bool = false

    var body: some View {
        let title: String = didCopy ? "Copied" : "Copy"
        let background: Color = didCopy ? .colorGreen : .colorFillMinimal
        let foreground: Color = didCopy ? .colorTextPrimaryInverted : .colorTextSecondary
        let label: String = didCopy ? "Copied" : accessibilityLabel
        let action = { copyToClipboard() }
        return Button(action: action) {
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(foreground)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .background(background, in: .capsule)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = value
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: Constant.confirmationNanoseconds)
            didCopy = false
        }
    }

    private enum Constant {
        static let confirmationNanoseconds: UInt64 = 1_400_000_000
    }
}

/// One worked example: what a member sends, and what the agent does with it.
private struct AgentReachExampleRow: View {
    let message: String
    let outcome: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text("“\(message)”")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
            Text(outcome)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignConstants.Spacing.step4x)
    }
}

#Preview("Both channels") {
    AgentReachSection(
        agentName: "Maple",
        phone: "+1 (615) 555-0142",
        email: "maple.9f3ab2@ai.convos.org"
    )
    .padding()
}

#Preview("Text only") {
    AgentReachSection(
        agentName: "Maple",
        phone: "+1 (615) 555-0142",
        email: nil
    )
    .padding()
}
