import ConvosCore
import Observation
import SwiftUI

enum JoinerPairingFlowState: Equatable {
    case showingPin(pin: String, expiresAt: Date)
    case syncing
    case completed
    case failed(String)
    case expired
}

@Observable
@MainActor
final class JoinerPairingSheetViewModel {
    var flowState: JoinerPairingFlowState
    var title: String = "Request to pair"
    var canDismiss: Bool = true
    var secondsRemaining: Int

    private let pairingId: String
    private let pin: String
    private let expiresAt: Date
    private let timeoutInterval: TimeInterval
    private var countdownTask: Task<Void, Never>?

    init(pairingId: String, timeoutInterval: TimeInterval = 60) {
        self.pairingId = pairingId
        self.timeoutInterval = timeoutInterval
        self.pin = PairingCoordinator.generatePin()
        self.expiresAt = Date().addingTimeInterval(timeoutInterval)
        self.secondsRemaining = Int(timeoutInterval)
        self.flowState = .showingPin(pin: pin, expiresAt: expiresAt)
    }

    var formattedPin: String {
        PairingCoordinator.formatPin(pin)
    }

    var initiatorDeviceName: String {
        "the other device"
    }

    func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let remaining = Int(self.expiresAt.timeIntervalSinceNow)
                if remaining <= 0 {
                    self.secondsRemaining = 0
                    self.flowState = .expired
                    break
                }
                self.secondsRemaining = remaining
            }
        }
    }

    func onPairingApproved() {
        countdownTask?.cancel()
        canDismiss = false
        flowState = .syncing
    }

    func onPairingCompleted() {
        title = "Device paired"
        flowState = .completed
        canDismiss = true
    }

    func onPairingFailed(_ message: String) {
        flowState = .failed(message)
        canDismiss = true
    }

    func cancel() {
        countdownTask?.cancel()
    }
}
