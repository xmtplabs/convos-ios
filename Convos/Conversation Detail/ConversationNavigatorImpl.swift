import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ConversationNavigatorImpl: @preconcurrency ConversationNavigator {
    var presentingConversationSettings: Bool = false
    var presentingProfileSettings: Bool = false
    var presentingConversationForked: Bool = false
    var presentingShareView: Bool = false
    var presentingRevealMediaInfoSheet: Bool = false
    var presentingPhotosInfoSheet: Bool = false
    var presentingAssistantConfirmation: Bool = false
    var presentingExplodedInviteInfo: Bool = false
    var presentingLockedConvoInfo: Bool = false
    var presentingProcessingPowerInfo: Bool = false
    var presentingFullConvoInfo: Bool = false
    var presentingAssistantInfo: Bool = false
    var presentingBackwardsSecrecyInfo: Bool = false

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConversationNavigator

    func present(conversationInfo: ConversationInfoNavigatorArgs) {
        presentingConversationSettings = true
    }

    func present(myInfo: MyInfoNavigatorArgs) {
        presentingProfileSettings = true
    }

    func present(memberProfile: MemberProfileNavigatorArgs) {}

    func present(shareInvite: ShareInviteNavigatorArgs) {
        presentingShareView = true
    }

    func present(newConversation: NewConversationNavigatorArgs) {}

    func present(reactions: ReactionsNavigatorArgs) {}

    func present(explodeInfo: ExplodeInfoNavigatorArgs) {}

    func present(lockedConvoInfo: LockedConvoInfoNavigatorArgs) {
        presentingLockedConvoInfo = true
    }

    func present(fullConvoInfo: FullConvoInfoNavigatorArgs) {
        presentingFullConvoInfo = true
    }

    func present(conversationForkedInfo: ConversationForkedInfoNavigatorArgs) {
        presentingConversationForked = true
    }

    func present(revealMediaInfo: RevealMediaInfoNavigatorArgs) {
        presentingRevealMediaInfoSheet = true
    }

    func present(photosInfo: PhotosInfoNavigatorArgs) {
        presentingPhotosInfoSheet = true
    }

    func present(assistantConfirmation: AssistantConfirmationNavigatorArgs) {
        presentingAssistantConfirmation = true
    }

    func present(assistantInfo: AssistantInfoNavigatorArgs) {
        presentingAssistantInfo = true
    }

    func present(processingPowerInfo: ProcessingPowerInfoNavigatorArgs) {
        presentingProcessingPowerInfo = true
    }

    func present(explodedInviteInfo: ExplodedInviteInfoNavigatorArgs) {
        presentingExplodedInviteInfo = true
    }

    func present(setupProfile: SetupProfileNavigatorArgs) {}

    func present(inviteAccepted: InviteAcceptedNavigatorArgs) {}

    func present(requestPushNotifications: RequestPushNotificationsNavigatorArgs) {}

    func present(backwardsSecrecyInfo: BackwardsSecrecyInfoNavigatorArgs) {
        presentingBackwardsSecrecyInfo = true
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
