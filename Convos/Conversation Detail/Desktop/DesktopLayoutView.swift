import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

// The scrollable desktop surface rendered behind the chat drawer in desktop
// mode. Replaces the old full-screen `DesktopWebView` background with a
// sectioned layout: the web view as the hero card, then an optional invite
// card (the same `InviteCodeBody` the transcript's index-0 invite cell and
// `InviteCodeOverlay` compose).
//
// The `ConversationDrawer` floats above this view; its collapsed resting
// height is shared via `ConversationDrawerMetrics.collapsedRestingHeight`.
// The web section is sized so it fills the space above the collapsed compose
// card, and the scroll content reserves a matching bottom margin so the last
// section can scroll clear of the resting card.

/// Everything the invite section needs to render `InviteCodeBody`. Mirrors
/// the arguments the message-list invite cell passes; the host builds one of
/// these when the conversation owns an inline invite card.
struct DesktopInviteSectionConfiguration {
    let conversation: Conversation
    let invite: Invite
    let mode: InviteCodeMode
    var initialSegment: ScanInviteSegment = .invite
    /// Fired with the decoded payload from either the live viewfinder or a
    /// picked screenshot.
    var onScannedCode: ((String) -> Void)?
    /// Forwarded to the share sheet completion so the caller can record a
    /// share metric.
    var onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?
}

struct DesktopLayoutView: View {
    /// Keys the web section's persisted cover snapshot.
    var conversationId: String = ""
    var webURL: URL?
    var inviteConfiguration: DesktopInviteSectionConfiguration?
    /// The drawer's live occupied height (keyboard included). The scroll content
    /// insets by it so the last section always clears whatever the drawer
    /// currently covers, at any detent and while typing. Defaults to the
    /// collapsed resting height for the first frame before the drawer reports.
    var drawerHeight: CGFloat = ConversationDrawerMetrics.collapsedRestingHeight
    /// Fired when the web section's page requests navigation away from the
    /// space URL; the host presents it in the desktop browser popup.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let availableWebHeight: CGFloat = proxy.size.height - ConversationDrawerMetrics.collapsedRestingHeight - Constant.sectionSpacing
            let webSectionHeight: CGFloat = max(availableWebHeight, Constant.minimumWebSectionHeight)
            let bottomInset: CGFloat = drawerHeight
            ScrollView {
                VStack(spacing: Constant.sectionSpacing) {
                    // The web section spans the full width with no inset or
                    // rounded corners; the remaining cards keep the horizontal
                    // margin.
                    DesktopWebSection(
                        conversationId: conversationId,
                        url: webURL,
                        height: webSectionHeight,
                        onNavigationRequest: onNavigationRequest
                    )
                    VStack(spacing: Constant.sectionSpacing) {
                        if let inviteConfiguration {
                            DesktopInviteSection(configuration: inviteConfiguration)
                        }
                    }
                    .padding(.horizontal, Constant.horizontalPadding)
                }
            }
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .background {
            Color.colorBackgroundSubtle
                .ignoresSafeArea()
        }
    }

    private enum Constant {
        static let sectionSpacing: CGFloat = DesignConstants.Spacing.step4x
        static let horizontalPadding: CGFloat = DesignConstants.Spacing.step4x
        static let minimumWebSectionHeight: CGFloat = 320.0
    }
}

/// The full-bleed web hero. It spans the layout edge to edge with no border or
/// corner radius. Scrolling inside the web view is disabled so the outer
/// desktop scroll owns the vertical gesture.
private struct DesktopWebSection: View {
    let conversationId: String
    let url: URL?
    let height: CGFloat
    let onNavigationRequest: @MainActor (URL) -> Void

    var body: some View {
        DesktopWebSurface(
            conversationId: conversationId,
            url: url,
            isScrollEnabled: false,
            onNavigationRequest: onNavigationRequest
        )
            .frame(height: height)
            .clipped()
            .accessibilityIdentifier("desktop-web-section")
    }
}

/// The invite card: the shared `InviteCodeBody` (Scan/Invite segmented
/// toggle) in section-card chrome, constructed exactly as the transcript's
/// index-0 invite cell does.
private struct DesktopInviteSection: View {
    let configuration: DesktopInviteSectionConfiguration

    var body: some View {
        let isInviteReady: Bool = !configuration.invite.isEmpty
        InviteCodeBody(
            conversation: configuration.conversation,
            encodedURLString: configuration.invite.inviteURLString,
            mode: configuration.mode,
            initialSegment: configuration.initialSegment,
            isInviteReady: isInviteReady,
            onScannedCode: configuration.onScannedCode,
            onShareCompleted: configuration.onShareCompleted
        )
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Constant.cornerRadius)
                .fill(DesignConstants.Colors.fillSubtle)
        }
        .accessibilityIdentifier("desktop-invite-section")
    }

    private enum Constant {
        static let cornerRadius: CGFloat = DesignConstants.CornerRadius.mediumLarge
    }
}

#Preview("With invite section") {
    DesktopLayoutView(
        inviteConfiguration: DesktopInviteSectionConfiguration(
            conversation: .mock(),
            invite: .mock(),
            mode: .inConvo
        )
    )
}

#Preview("Web only") {
    DesktopLayoutView()
}
