import ConvosCore
import SwiftUI

/// Extracted modifiers carrying the 17 Bool-keyed metrics `.onChange`
/// observers for the conversation screen. Split into two modifiers
/// because chaining all 17 into a single `body(content:)` blew past the
/// 300ms type-check threshold (see CLAUDE.md build-performance notes).
/// The two object-keyed observers (`presentingProfileForMember`,
/// `presentingReactionsForMessage`) stay on `ConversationView.body` —
/// only two modifiers and their types (`ConversationMember?` /
/// `AnyMessage?`) don't fit a uniform shape.
extension ConversationView {
    struct MetricsObserversPart1: ViewModifier {
        let presentingConversationSettings: Bool
        let presentingProfileSettings: Bool
        let presentingShareView: Bool
        let presentingConversationForked: Bool
        let presentingExplodedInviteInfo: Bool
        let presentingAgentsIntro: Bool
        let presentingPaywall: Bool
        let showingAgentsInfo: Bool
        let showingLockedInfo: Bool

        let onConversationSettingsChanged: (Bool, Bool) -> Void
        let onProfileSettingsChanged: (Bool, Bool) -> Void
        let onShareViewChanged: (Bool, Bool) -> Void
        let onConversationForkedChanged: (Bool, Bool) -> Void
        let onExplodedInviteInfoChanged: (Bool, Bool) -> Void
        let onAgentsIntroChanged: (Bool, Bool) -> Void
        let onPaywallChanged: (Bool, Bool) -> Void
        let onAgentsInfoChanged: (Bool, Bool) -> Void
        let onLockedInfoChanged: (Bool, Bool) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: presentingConversationSettings) { o, n in onConversationSettingsChanged(o, n) }
                .onChange(of: presentingProfileSettings) { o, n in onProfileSettingsChanged(o, n) }
                .onChange(of: presentingShareView) { o, n in onShareViewChanged(o, n) }
                .onChange(of: presentingConversationForked) { o, n in onConversationForkedChanged(o, n) }
                .onChange(of: presentingExplodedInviteInfo) { o, n in onExplodedInviteInfoChanged(o, n) }
                .onChange(of: presentingAgentsIntro) { o, n in onAgentsIntroChanged(o, n) }
                .onChange(of: presentingPaywall) { o, n in onPaywallChanged(o, n) }
                .onChange(of: showingAgentsInfo) { o, n in onAgentsInfoChanged(o, n) }
                .onChange(of: showingLockedInfo) { o, n in onLockedInfoChanged(o, n) }
        }
    }

    struct MetricsObserversPart2: ViewModifier {
        let showingFullInfo: Bool
        let presentingRevealMediaInfo: Bool
        let presentingPhotosInfo: Bool
        let presentingAgentBuilder: Bool
        let presentingNewConvoForInvite: Bool
        let presentingNewConvoForAgentShare: Bool
        let presentingAddFromContactsPicker: Bool

        let onFullInfoChanged: (Bool, Bool) -> Void
        let onRevealMediaInfoChanged: (Bool, Bool) -> Void
        let onPhotosInfoChanged: (Bool, Bool) -> Void
        let onAgentBuilderChanged: (Bool, Bool) -> Void
        let onNewConvoInviteChanged: (Bool, Bool) -> Void
        let onNewConvoAgentShareChanged: (Bool, Bool) -> Void
        let onAddFromContactsChanged: (Bool, Bool) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: showingFullInfo) { o, n in onFullInfoChanged(o, n) }
                .onChange(of: presentingRevealMediaInfo) { o, n in onRevealMediaInfoChanged(o, n) }
                .onChange(of: presentingPhotosInfo) { o, n in onPhotosInfoChanged(o, n) }
                .onChange(of: presentingAgentBuilder) { o, n in onAgentBuilderChanged(o, n) }
                .onChange(of: presentingNewConvoForInvite) { o, n in onNewConvoInviteChanged(o, n) }
                .onChange(of: presentingNewConvoForAgentShare) { o, n in onNewConvoAgentShareChanged(o, n) }
                .onChange(of: presentingAddFromContactsPicker) { o, n in onAddFromContactsChanged(o, n) }
        }
    }

    struct MetricsObserversPart3: ViewModifier {
        let presentingProfileForMember: ConversationMember?
        let presentingReactionsForMessage: AnyMessage?
        let presentingThinkingDetail: ThinkingSessionDescriptor?

        let onMemberProfileChanged: (ConversationMember?, ConversationMember?) -> Void
        let onReactionsChanged: (AnyMessage?, AnyMessage?) -> Void
        let onThinkingDetailChanged: (ThinkingSessionDescriptor?, ThinkingSessionDescriptor?) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: presentingProfileForMember) { o, n in onMemberProfileChanged(o, n) }
                .onChange(of: presentingReactionsForMessage) { o, n in onReactionsChanged(o, n) }
                .onChange(of: presentingThinkingDetail) { o, n in onThinkingDetailChanged(o, n) }
        }
    }
}
