import SwiftUI

enum NotificationPermissionState {
    case request
    case enabled
    case denied
}

enum ConversationOnboardingState: Equatable {
    static let waitingForInviteAcceptanceDelay: TimeInterval = 0.8
}
