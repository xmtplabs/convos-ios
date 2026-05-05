import ConvosCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantBuilderViewModel: Identifiable {
    enum Phase {
        case bootstrap
        case focus
        case stopped
    }

    let session: any SessionManagerProtocol
    private(set) var phase: Phase = .bootstrap

    @ObservationIgnored
    private var dismissAction: DismissAction?

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    func setDismissAction(_ dismiss: DismissAction) {
        self.dismissAction = dismiss
    }

    func dismiss() {
        dismissAction?()
    }
}
