import ConvosCore
import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ConnectionsNavigatorImpl: @preconcurrency ConnectionsNavigator {
    var pendingGrantRequest: PendingGrantRequest?

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConnectionsNavigator

    func present(connectionGrant args: ConnectionGrantNavigatorArgs) {
        pendingGrantRequest = PendingGrantRequest(
            serviceId: args.serviceId,
            conversationId: args.conversationId
        )
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
