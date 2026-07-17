import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ConversationNavigatorImpl: @preconcurrency ConversationNavigator, NavigatorLifecycle {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    func closeContext() -> ScreenContext {
        let secs: Float = screenAppearAt.map { Float(Date().timeIntervalSince($0)) } ?? 0
        screenAppearAt = nil
        return ScreenContext(durationSecs: secs)
    }

    func present(paywall: PaywallNavigatorArgs) {}
    func present(conversationInfo: ConversationInfoNavigatorArgs) {}
    func present(myInfo: MyInfoNavigatorArgs) {}
    func present(memberProfile: MemberProfileNavigatorArgs) {}
    func present(shareInvite: ShareInviteNavigatorArgs) {}
    func present(newConversation: NewConversationNavigatorArgs) {}
    func present(reactions: ReactionsNavigatorArgs) {}
    func present(explodeInfo: ExplodeInfoNavigatorArgs) {}
    func present(lockedConvoInfo: LockedConvoInfoNavigatorArgs) {}
    func present(fullConvoInfo: FullConvoInfoNavigatorArgs) {}
    func present(conversationForkedInfo: ConversationForkedInfoNavigatorArgs) {}
    // Required by the convos-shared ConversationNavigator protocol, so it cannot be
    // dropped here. Now a no-op since the reveal-media feature was removed.
    func present(revealMediaInfo: RevealMediaInfoNavigatorArgs) {}
    func present(photosInfo: PhotosInfoNavigatorArgs) {}
    func present(assistantConfirmation: AssistantConfirmationNavigatorArgs) {}
    func present(agentInfo: AgentInfoNavigatorArgs) {}
    func present(agentPowerInfo: AgentPowerInfoNavigatorArgs) {}
    func present(explodedInviteInfo: ExplodedInviteInfoNavigatorArgs) {}
    func present(setupProfile: SetupProfileNavigatorArgs) {}
    func present(inviteAccepted: InviteAcceptedNavigatorArgs) {}
    func present(requestPushNotifications: RequestPushNotificationsNavigatorArgs) {}
    func present(backwardsSecrecyInfo: BackwardsSecrecyInfoNavigatorArgs) {}
    func present(addMembers: AddMembersNavigatorArgs) {}
    func present(contactCard: ContactCardNavigatorArgs) {}
    func present(agentTemplateContactCard: AgentTemplateContactCardNavigatorArgs) {}
    func present(agentBuilder: AgentBuilderNavigatorArgs) {}
    func present(thinkingDetail: ThinkingDetailNavigatorArgs) {}
    func present(attachmentPreview: AttachmentPreviewNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}
