import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

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

/// The one control vocabulary for actions that live inside a bubble: a
/// bordered capsule in the affirmative accent, tall enough to be a legal
/// touch target on its own. Every recovery action in the transcript - try
/// again or check again - is this control, so the transcript never shows two
/// shapes for the same kind of choice.
struct AgentBubbleAction: View {
    let title: String
    var tint: Color = .colorGreen
    var accessibilityIdentifier: String?
    var accessibilityHint: String?
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(tint)
            .frame(minHeight: Constant.minimumTargetHeight)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            .accessibilityHint(accessibilityHint ?? "")
    }

    private enum Constant {
        static let minimumTargetHeight: CGFloat = 44.0
    }
}

/// The turn this device is watching. It is the only place in the app where
/// waiting is the content, so it says three true things at once: that the
/// agent is working (the same pulsing dot a convo shows while an agent
/// thinks), how long it has been (real seconds, monospaced so the number
/// never shifts under itself), and what stopping this phone's wait means.
///
/// One `TimelineView` ticks the whole inside of the bubble once a second: the
/// counter, and the moment the watch deadline passes and "Check again"
/// appears. It exists only while a turn is in flight, so nothing ticks once
/// the transcript settles, and the pulsing dot sits outside it so a redraw
/// never restarts its animation.
struct AgentPendingBubble: View {
    let startedAt: Date
    /// When the copy switches from "working" to "still working, you will get
    /// a notification", and the check-again escape hatch appears.
    let deadline: Date
    let workingMessage: String
    let pastDeadlineMessage: String
    let onCheckAgain: () -> Void

    private var lineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
    }

    var body: some View {
        AgentChatBubble(isOutgoing: false) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
                workingDot
                ticking
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The convo's own "an agent is working on this" mark, sized to the line
    /// it sits on so it stays optically centered on the first line as the
    /// message wraps and as Dynamic Type grows.
    private var workingDot: some View {
        PulsingCircleView.thinkingIndicator
            .frame(width: Constant.dotSize, height: Constant.dotSize)
            .frame(height: lineHeight)
            .accessibilityHidden(true)
    }

    private var ticking: some View {
        TimelineView(.periodic(from: startedAt, by: Constant.tick)) { context in
            let isPastDeadline: Bool = context.date >= deadline
            let seconds: Int = Int(max(0, context.date.timeIntervalSince(startedAt)))
            let message: String = isPastDeadline ? pastDeadlineMessage : workingMessage
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DesignConstants.Spacing.step2x)
                    elapsed(seconds)
                }
                Text(Constant.stopWaitingHint)
                    .font(.caption)
                    .foregroundStyle(.colorTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-turn-stop-waiting-hint")
                if isPastDeadline {
                    AgentBubbleAction(
                        title: "Check again",
                        accessibilityIdentifier: "agent-turn-check-again",
                        action: onCheckAgain
                    )
                }
            }
        }
    }

    private func elapsed(_ seconds: Int) -> some View {
        Text("\(seconds)s")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.colorTextTertiary)
            .frame(height: lineHeight)
            .accessibilityLabel("\(seconds) seconds so far")
            .accessibilityIdentifier("agent-turn-elapsed")
    }

    private enum Constant {
        static let dotSize: CGFloat = 10.0
        static let stopWaitingHint: String = "The agent keeps working. Only this iPhone stops waiting."
        static let tick: TimeInterval = 1.0
    }
}

/// The line at the head of the transcript naming what leaves Convos when you
/// send. It sits with the transcript, not under the composer, where it used
/// to compete with the field it was printed beneath.
struct AgentTranscriptNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.colorTextTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.bottom, DesignConstants.Spacing.step2x)
    }
}

/// The transcript before anything has been sent. It teaches the one thing
/// that is different about this chat - the work happens elsewhere and takes
/// time - rather than reporting that a list is empty.
struct AgentTranscriptEmptyState: View {
    let provider: ExternalAgentProvider

    var body: some View {
        ContentUnavailableView(
            "Send \(provider.displayName) some work",
            systemImage: provider.symbolName,
            description: Text(AgentSetupCopy.chatEmptyState)
        )
        .padding(.top, DesignConstants.Spacing.step8x)
        .accessibilityIdentifier("agent-chat-empty-state")
    }
}

extension View {
    /// The clear-history confirmation, in one place so the transcript and its
    /// previews ask the question with the same words. It names the agent
    /// because the scope is that agent's history, says what goes and what
    /// stays, and says that it cannot be undone.
    func agentClearHistoryDialog(
        isPresented: Binding<Bool>,
        providerName: String,
        onClear: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Clear \(providerName) history?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AgentSetupCopy.clearHistoryWarning)
        }
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
