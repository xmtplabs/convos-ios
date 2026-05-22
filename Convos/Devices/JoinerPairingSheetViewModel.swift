import ConvosCore
import CryptoKit
import Observation
import SwiftUI

enum JoinerPairingFlowState: Equatable {
    case connecting
    case needsDataDeletion
    case deletingData
    case pinEntry(initiatorInboxId: String)
    case waitingForEmoji(emojis: [String])
    case syncing
    case completed
    case failed(String)
    case expired
}

@Observable
@MainActor
final class JoinerPairingSheetViewModel: Identifiable {
    nonisolated let id: String
    var flowState: JoinerPairingFlowState
    var title: String = "Request to pair"
    var canDismiss: Bool = true
    var secondsRemaining: Int
    var enteredPin: String = ""

    private let pairingId: String
    private let expiresAt: Date
    private let timeoutInterval: TimeInterval
    private let pairingService: any PairingServiceProtocol
    private let initiatorName: String?
    private var countdownTask: Task<Void, Never>?
    @ObservationIgnored
    private let observers: PairingNotificationObservers
    private var initiatorInboxId: String?

    private let onPairingAdopted: (@MainActor () async -> Void)?
    private let onApplyAdoptedProfile: (@MainActor (_ displayName: String?, _ imageAssetIdentifier: String?) async -> Void)?
    private let onDeleteExistingData: (@MainActor () async throws -> Void)?
    private let checkHasExistingData: (@MainActor () async -> Bool)?
    private var adoptedDisplayName: String?
    private var adoptedImageAssetIdentifier: String?

    init(
        pairingId: String,
        expiresAt: Date? = nil,
        initiatorName: String? = nil,
        timeoutInterval: TimeInterval = 60,
        pairingService: any PairingServiceProtocol,
        onPairingAdopted: (@MainActor () async -> Void)? = nil,
        onApplyAdoptedProfile: (@MainActor (_ displayName: String?, _ imageAssetIdentifier: String?) async -> Void)? = nil,
        onDeleteExistingData: (@MainActor () async throws -> Void)? = nil,
        checkHasExistingData: (@MainActor () async -> Bool)? = nil
    ) {
        self.id = pairingId
        self.pairingId = pairingId
        self.timeoutInterval = timeoutInterval
        self.initiatorName = initiatorName
        self.pairingService = pairingService
        self.onPairingAdopted = onPairingAdopted
        self.onApplyAdoptedProfile = onApplyAdoptedProfile
        self.onDeleteExistingData = onDeleteExistingData
        self.checkHasExistingData = checkHasExistingData
        self.expiresAt = expiresAt ?? Date().addingTimeInterval(timeoutInterval)
        self.secondsRemaining = max(0, Int(self.expiresAt.timeIntervalSinceNow))
        self.flowState = .connecting
        self.observers = PairingNotificationObservers()

        observeNotifications()
    }

    private func observeNotifications() {
        observers.add(
            for: .pairingDidReceiveIdentityShare
        ) { [weak self] notification in
            guard let self else { return }
            let displayName = notification.userInfo?["displayName"] as? String
            let imageAssetIdentifier = notification.userInfo?["imageAssetIdentifier"] as? String
            Task { @MainActor in
                self.adoptedDisplayName = displayName
                self.adoptedImageAssetIdentifier = imageAssetIdentifier
                self.onPairingCompleted()
            }
        }

        observers.add(
            for: .pairingDidReceiveError
        ) { [weak self] notification in
            guard let self else { return }
            let message = notification.userInfo?["message"] as? String ?? "Pairing failed"
            Task { @MainActor in
                self.onPairingFailed(message)
            }
        }

        observers.add(
            for: .pairingDidReceivePin
        ) { [weak self] notification in
            guard let self else { return }
            guard let pin = notification.userInfo?["pin"] as? String,
                  let senderInboxId = notification.userInfo?["initiatorInboxId"] as? String
            else { return }
            Task { @MainActor in
                self.onPinReceived(pin, from: senderInboxId)
            }
        }
    }

    var initiatorDeviceName: String {
        initiatorName ?? "the other device"
    }

    var formattedPin: String {
        PairingCoordinator.formatPin(enteredPin)
    }

    var isPinComplete: Bool {
        enteredPin.count == 6
    }

    func sendJoinRequest() async {
        // Check first whether the device has any real conversation data —
        // i.e. anything the user would actually lose. A placeholder
        // identity + pre-warmed unused convo cache from silent identity
        // creation doesn't count. Only block on real history.
        if let checkHasExistingData, await checkHasExistingData() {
            flowState = .needsDataDeletion
            return
        }
        do {
            try await pairingService.start()
            try await pairingService.sendPairingJoinRequest(
                slug: pairingId,
                deviceName: DeviceInfo.deviceName
            )
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    func confirmDeleteAndPair() async {
        guard let onDeleteExistingData else {
            flowState = .failed("This device can't be reset from here.")
            return
        }
        flowState = .deletingData
        canDismiss = false
        do {
            try await onDeleteExistingData()
        } catch {
            flowState = .failed("Couldn't delete existing data: \(error.localizedDescription)")
            canDismiss = true
            return
        }
        canDismiss = true
        flowState = .connecting
        await sendJoinRequest()
    }

    func triggerConfirmDeleteAndPair() {
        Task { await confirmDeleteAndPair() }
    }

    func submitPin() async {
        guard let initiatorInboxId, isPinComplete else { return }

        do {
            try await pairingService.sendPinEcho(enteredPin, to: initiatorInboxId)

            countdownTask?.cancel()

            let joinerInboxId = await pairingService.pairingInboxId() ?? ""
            let emojis = PairingCoordinator.emojiFingerprint(
                inboxA: initiatorInboxId,
                inboxB: joinerInboxId,
                pin: enteredPin
            )
            title = "Confirm pairing"
            flowState = .waitingForEmoji(emojis: emojis)
        } catch {
            flowState = .failed(error.localizedDescription)
        }
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

    private func onPinReceived(_ pin: String, from senderInboxId: String) {
        initiatorInboxId = senderInboxId
        flowState = .pinEntry(initiatorInboxId: senderInboxId)
    }

    func onPairingCompleted() {
        countdownTask?.cancel()
        title = "Adopting identity"
        flowState = .syncing
        canDismiss = false
        let capturedDisplayName = adoptedDisplayName
        let capturedImage = adoptedImageAssetIdentifier
        Task { @MainActor in
            await onPairingAdopted?()
            await onApplyAdoptedProfile?(capturedDisplayName, capturedImage)
            NotificationCenter.default.post(name: .pairingDidCompleteSuccessfully, object: nil)
            title = "Device paired"
            flowState = .completed
            canDismiss = true
        }
    }

    func onPairingFailed(_ message: String) {
        flowState = .failed(message)
        canDismiss = true
    }

    func cancel() {
        countdownTask?.cancel()
        Task {
            await pairingService.stop()
        }
    }
}
