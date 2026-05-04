import ConvosCore
import Foundation
import NavigationMetrics
import Observation
import SwiftUI

@MainActor
@Observable
final class ConversationsNavigatorImpl: @preconcurrency ConversationsNavigator {
    var selectedConversationId: String?
    var presentingAppSettings: Bool = false
    var newConversationViewModel: NewConversationViewModel?
    var conversationPendingExplosion: Conversation?
    var pendingGrantRequest: PendingGrantRequest?
    var presentingExplodeInfo: Bool = false
    var presentingPinLimitInfo: Bool = false

    @ObservationIgnored
    var conversationLookup: ((String) -> Conversation?)?

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    @ObservationIgnored
    private let session: any SessionManagerProtocol
    @ObservationIgnored
    let metricsDelegate: CollectorDelegate

    @ObservationIgnored
    let appSettingsNavState: AppSettingsNavigatorImpl
    @ObservationIgnored
    let appSettingsNavigator: any AppSettingsNavigator

    init(session: any SessionManagerProtocol, metricsDelegate: CollectorDelegate) {
        self.session = session
        self.metricsDelegate = metricsDelegate
        let appSettingsImpl = AppSettingsNavigatorImpl()
        self.appSettingsNavState = appSettingsImpl
        self.appSettingsNavigator = AppSettingsCollector(
            instance: appSettingsImpl,
            delegate: metricsDelegate
        )
    }

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConversationsNavigator

    func navigateTo(conversation args: ConversationNavigatorArgs) {
        guard selectedConversationId != args.conversationId else { return }
        selectedConversationId = args.conversationId
    }

    func present(appSettings: AppSettingsNavigatorArgs) {
        presentingAppSettings = true
    }

    func present(newConversation args: NewConversationNavigatorArgs) {
        let mode: Convos.NewConversationMode = switch args.mode {
        case .create: .newConversation
        case .scanner: .scanner
        case .joinInvite: .joinInvite(code: args.inviteCode ?? "")
        }
        newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: mode,
            metricsDelegate: metricsDelegate
        )
    }

    func present(explodeConfirmation args: ExplodeConfirmationNavigatorArgs) {
        conversationPendingExplosion = conversationLookup?(args.conversationId)
    }

    func present(connectionGrant args: ConnectionGrantNavigatorArgs) {
        pendingGrantRequest = PendingGrantRequest(
            serviceId: args.serviceId,
            conversationId: args.conversationId
        )
    }

    func present(explodeInfo: ExplodeInfoNavigatorArgs) {
        presentingExplodeInfo = true
    }

    func present(pinLimitInfo: PinLimitInfoNavigatorArgs) {
        presentingPinLimitInfo = true
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
