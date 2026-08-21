import ConvosCore
import SwiftUI

/// The transcript's bubble vocabulary, kept in one file so the agent chat
/// speaks the same visual language as a convo. Shape, fill, text color and
/// padding all come from `MessageContainer` / `MessageBubble` in the composer
/// package: a 20pt rounded rectangle whose corner on the sender's side is
/// clipped to 4pt, `colorBubble` outgoing and `colorBubbleIncoming` incoming,
/// `.callout` text, 12pt horizontal and 10pt vertical padding.
///
/// It is a local rebuild rather than a reuse because `MessageContainer` is
/// internal to `ConvosComposer` and takes a `Message`; only the geometry is
/// shared, and these constants are the contract.
struct AgentChatBubble<Content: View>: View {
    let isOutgoing: Bool
    @ViewBuilder let content: () -> Content

    private var shape: UnevenRoundedRectangle {
        let radius: CGFloat = AgentBubbleConstant.cornerRadius
        let tail: CGFloat = AgentBubbleConstant.tailRadius
        if isOutgoing {
            return .rect(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: tail,
                topTrailingRadius: radius
            )
        }
        return .rect(
            topLeadingRadius: radius,
            bottomLeadingRadius: tail,
            bottomTrailingRadius: radius,
            topTrailingRadius: radius
        )
    }

    /// Low layout priority so the bubble takes the width it needs and the
    /// spacer absorbs the rest, exactly like a message row.
    private var spacer: some View {
        Spacer()
            .frame(minWidth: AgentBubbleConstant.minimumOppositeInset)
            .layoutPriority(-1)
    }

    var body: some View {
        let fill: Color = isOutgoing ? .colorBubble : .colorBubbleIncoming
        let text: Color = isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary
        HStack(alignment: .bottom, spacing: 0.0) {
            if isOutgoing {
                spacer
            }
            content()
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, AgentBubbleConstant.verticalPadding)
                .background(fill)
                .foregroundStyle(text)
                .compositingGroup()
                .clipShape(shape)
            if !isOutgoing {
                spacer
            }
        }
    }
}

/// The bubble geometry, at file scope because `AgentChatBubble` is generic
/// and a generic type cannot hold static stored properties. Values mirror
/// `Constant.bubbleCornerRadius` and `MessageBubble`'s padding in the
/// composer package.
private enum AgentBubbleConstant {
    static let cornerRadius: CGFloat = 20.0
    static let tailRadius: CGFloat = 4.0
    static let verticalPadding: CGFloat = 10.0
    static let minimumOppositeInset: CGFloat = 50.0
}

/// What the user sent. Outgoing side, outgoing fill, message type.
struct AgentUserBubble: View {
    let text: String

    var body: some View {
        AgentChatBubble(isOutgoing: true) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A finished answer, with whatever links came back under it.
struct AgentReplyBubble: View {
    let message: String?
    let links: [AgentRelayLink]
    let onOpenLink: (AgentRelayLink) -> Void

    var body: some View {
        AgentChatBubble(isOutgoing: false) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(links) { link in
                    let action = { onOpenLink(link) }
                    AgentLinkRow(link: link, action: action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A link an agent returned. Rendered the way every other link in the app is
/// rendered - the surrounding text color, single underline (see
/// `LinkDetectingTextView`) - rather than as a colored icon-and-label chip,
/// so a link inside a bubble reads as a link and not as a button.
struct AgentLinkRow: View {
    let link: AgentRelayLink
    let action: () -> Void

    private var label: String {
        guard let title = link.title, !title.isEmpty else {
            return link.url.host(percentEncoded: false) ?? link.url.absoluteString
        }
        return title
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(label)
                    .font(.callout)
                    .underline()
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .opacity(Constant.glyphOpacity)
            }
            .frame(minHeight: Constant.minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-turn-link")
        .accessibilityHint("Opens after you confirm the address")
    }

    private enum Constant {
        static let minimumRowHeight: CGFloat = 32.0
        static let glyphOpacity: Double = 0.6
    }
}

/// Everything that is not an answer: working, stopped waiting, failed,
/// expired. Same incoming bubble so the transcript keeps one rhythm, but
/// secondary type so it never reads as something the agent said.
struct AgentStatusBubble<Actions: View>: View {
    let systemImage: String
    let message: String
    var glyphTint: Color = .colorTextSecondary
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        AgentChatBubble(isOutgoing: false) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: systemImage)
                        .font(.footnote)
                        .foregroundStyle(glyphTint)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The recovery action on a status bubble. A small bordered capsule in the
/// affirmative accent - the same control the setup screens use for their
/// primary step, one size down because it sits inside a bubble.
struct AgentBubbleAction: View {
    let title: String
    var tint: Color = .colorGreen
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(tint)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

/// A send that produced no bubble of its own - the request never reached the
/// relay, so there is nothing in the transcript to attach the failure to.
/// Sits above the composer, names the problem and the way out, and can be
/// dismissed; it never silently swallows itself.
struct AgentComposerNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.colorCaution)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: DesignConstants.Spacing.step6x, height: DesignConstants.Spacing.step6x)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, DesignConstants.Spacing.step3x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.colorCaution.opacity(Constant.noticeFillOpacity), in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityIdentifier("agent-chat-error-notice")
    }

    private enum Constant {
        static let noticeFillOpacity: Double = 0.15
    }
}

// MARK: - Previews

private func previewLink(_ host: String, title: String?) -> AgentRelayLink {
    AgentRelayLink(title: title, url: URL(string: "https://\(host)/doc/1") ?? URL(fileURLWithPath: "/"))
}

#Preview("Transcript states") {
    ScrollView {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            AgentUserBubble(text: "Draft the packing list for the Lisbon trip and share the doc.")
            AgentReplyBubble(
                message: "Done. I drafted the list from last year's trip and dropped it in a doc.",
                links: [previewLink("docs.google.com", title: "Lisbon packing list")],
                onOpenLink: { _ in }
            )
            AgentUserBubble(text: "Book the airport transfer too.")
            AgentStatusBubble(
                systemImage: "clock",
                message: "Working on its own platform - 4 min"
            ) {
                AgentBubbleAction(title: "Stop waiting", tint: .colorTextSecondary, action: {})
            }
            AgentStatusBubble(
                systemImage: "clock.arrow.circlepath",
                message: "Stopped waiting on this iPhone. If it replies, the answer arrives here."
            ) {
                AgentBubbleAction(title: "Check again", action: {})
            }
            AgentStatusBubble(
                systemImage: "exclamationmark.triangle.fill",
                message: "Convos is not signed in yet. Try again in a moment.",
                glyphTint: .colorCaution
            ) {
                AgentBubbleAction(title: "Try again", action: {})
            }
            AgentStatusBubble(
                systemImage: "hourglass",
                message: "This request expired. Send it again."
            ) {
                AgentBubbleAction(title: "Try again", action: {})
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Composer notice") {
    VStack(spacing: DesignConstants.Spacing.step4x) {
        AgentComposerNotice(message: "Convos is not signed in yet. Try again in a moment.", onDismiss: {})
        AgentComposerNotice(
            message: "Town turned down the webhook secret. Copy it again from the routine's webhook settings.",
            onDismiss: {}
        )
    }
    .padding(DesignConstants.Spacing.step4x)
    .background(.colorBackgroundSurfaceless)
}
