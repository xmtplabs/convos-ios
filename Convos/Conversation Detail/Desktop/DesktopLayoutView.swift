import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

// The scrollable desktop surface rendered behind the chat drawer in desktop
// mode. Replaces the old full-screen `DesktopWebView` background with a
// sectioned layout: the web view as the hero card, then an optional invite
// card (the same `InviteCodeBody` the transcript's index-0 invite cell and
// `InviteCodeOverlay` compose), then clearly-stubbed placeholder cards for
// upcoming sections (Activity, Files).
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
    var webURL: URL?
    var inviteConfiguration: DesktopInviteSectionConfiguration?
    /// The drawer's live occupied height (keyboard included). The scroll content
    /// insets by it so the last section always clears whatever the drawer
    /// currently covers, at any detent and while typing. Defaults to the
    /// collapsed resting height for the first frame before the drawer reports.
    var drawerHeight: CGFloat = ConversationDrawerMetrics.collapsedRestingHeight

    var body: some View {
        GeometryReader { proxy in
            let availableWebHeight: CGFloat = proxy.size.height - ConversationDrawerMetrics.collapsedRestingHeight - Constant.sectionSpacing
            let webSectionHeight: CGFloat = max(availableWebHeight, Constant.minimumWebSectionHeight)
            let bottomInset: CGFloat = drawerHeight
            ScrollView {
                VStack(spacing: Constant.sectionSpacing) {
                    DesktopWebSection(url: webURL, height: webSectionHeight)
                    if let inviteConfiguration {
                        DesktopInviteSection(configuration: inviteConfiguration)
                    }
                    DesktopPlaceholderSection(title: "Activity")
                    DesktopPlaceholderSection(title: "Files")
                }
                .padding(.horizontal, Constant.horizontalPadding)
            }
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .background {
            Color.colorBackgroundSurfaceless
                .ignoresSafeArea()
        }
    }

    private enum Constant {
        static let sectionSpacing: CGFloat = DesignConstants.Spacing.step4x
        static let horizontalPadding: CGFloat = DesignConstants.Spacing.step4x
        static let minimumWebSectionHeight: CGFloat = 320.0
    }
}

/// The hero web card. Scrolling inside the web view is disabled so the outer
/// desktop scroll owns the vertical gesture.
private struct DesktopWebSection: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        DesktopWebView(url: url, isScrollEnabled: false)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Constant.cornerRadius))
            .accessibilityIdentifier("desktop-web-section")
    }

    private enum Constant {
        static let cornerRadius: CGFloat = DesignConstants.CornerRadius.mediumLarge
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

/// A clearly-stubbed card for a desktop section that doesn't exist yet.
private struct DesktopPlaceholderSection: View {
    let title: String

    var body: some View {
        let identifier: String = "desktop-placeholder-section-\(title.lowercased())"
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
            RoundedRectangle(cornerRadius: Constant.fillCornerRadius)
                .fill(.colorFillTertiary)
                .frame(height: Constant.fillHeight)
        }
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Constant.cornerRadius)
                .fill(DesignConstants.Colors.fillSubtle)
        }
        .accessibilityIdentifier(identifier)
    }

    private enum Constant {
        static let cornerRadius: CGFloat = DesignConstants.CornerRadius.mediumLarge
        static let fillCornerRadius: CGFloat = DesignConstants.CornerRadius.regular
        static let fillHeight: CGFloat = 120.0
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
