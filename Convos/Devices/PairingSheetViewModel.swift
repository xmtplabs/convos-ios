import ConvosCore
import Observation
import SwiftUI

enum PairingFlowState: Equatable {
    case qrCode(url: String)
    case showingPin(pin: String, deviceName: String)
    case emojiConfirmation(emojis: [String], deviceName: String)
    case syncing
    case completed(deviceName: String)
    case failed(String)
    case expired
}

@Observable
@MainActor
final class PairingSheetViewModel {
    var flowState: PairingFlowState = .qrCode(url: "")
    var canDismiss: Bool = true
    var title: String = "Pair new device"
    var secondsRemaining: Int = 60

    private let pairingService: any PairingServiceProtocol
    private let appGroupIdentifier: String?
    private let timeoutInterval: TimeInterval
    private(set) var coordinator: PairingCoordinator?
    private var joinerDeviceName: String = "New Device"
    private var joinerInboxId: String?
    private var expiresAt: Date = .distantFuture
    private var countdownTask: Task<Void, Never>?
    @ObservationIgnored
    private let observers: PairingNotificationObservers

    init(
        pairingService: any PairingServiceProtocol,
        timeoutInterval: TimeInterval = 120,
        appGroupIdentifier: String? = nil
    ) {
        self.pairingService = pairingService
        self.appGroupIdentifier = appGroupIdentifier
        self.timeoutInterval = timeoutInterval
        self.secondsRemaining = Int(timeoutInterval)
        self.observers = PairingNotificationObservers()
        observeNotifications()
    }

    private func observeNotifications() {
        observers.add(for: .pairingDidReceiveJoinRequest) { [weak self] notification in
            guard let self,
                  let joinerInboxId = notification.userInfo?["joinerInboxId"] as? String,
                  let deviceName = notification.userInfo?["deviceName"] as? String
            else { return }
            Task { @MainActor in
                await self.onJoinRequestReceived(deviceName: deviceName, joinerInboxId: joinerInboxId)
            }
        }
        observers.add(for: .pairingDidReceivePinEcho) { [weak self] notification in
            guard let self,
                  let pin = notification.userInfo?["pin"] as? String,
                  let joinerInboxId = notification.userInfo?["joinerInboxId"] as? String
            else { return }
            Task { @MainActor in
                await self.onPinEchoReceived(pin: pin, from: joinerInboxId)
            }
        }
        observers.add(for: .pairingDidReceiveError) { [weak self] notification in
            guard let self,
                  let message = notification.userInfo?["message"] as? String
            else { return }
            Task { @MainActor in
                self.flowState = .failed(message)
                self.canDismiss = true
            }
        }
    }

    func startPairing() async {
        let coordinator = PairingCoordinator(pairingService: pairingService, timeoutInterval: timeoutInterval)
        self.coordinator = coordinator

        expiresAt = Date().addingTimeInterval(timeoutInterval)
        let expiresAtUnix = Int(expiresAt.timeIntervalSince1970)

        do {
            try await pairingService.start()
            let slug = try await pairingService.createPairingInvite(expiresAt: expiresAt)
            let initiatorInboxId = await pairingService.pairingInboxId() ?? ""

            let domain = ConfigManager.shared.associatedDomain
            var allowedChars: CharacterSet = .urlQueryAllowed
            allowedChars.remove(charactersIn: "&=")
            let encodedName = DeviceInfo.deviceName.addingPercentEncoding(withAllowedCharacters: allowedChars) ?? ""
            let inviteURL = "https://\(domain)/pair/\(slug)?expires=\(expiresAtUnix)&name=\(encodedName)"

            try await coordinator.startPairing(inviteURL: inviteURL, initiatorInboxId: initiatorInboxId)
            QAEvent.emit(.pairing, "pairing_url_created", ["url": inviteURL])
            secondsRemaining = Int(timeoutInterval)
            flowState = .qrCode(url: inviteURL)
            startCountdown()
        } catch {
            Log.error("Pairing start failed: \(error)")
            flowState = .failed(error.localizedDescription)
        }
    }

    private func startCountdown() {
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

    func onJoinRequestReceived(deviceName: String, joinerInboxId: String) async {
        guard let coordinator else { return }

        do {
            // Let the coordinator validate first — it rejects duplicate
            // join requests when already mid-handshake. Only after the
            // coordinator transitions to `.showingPin` for *this* joiner
            // do we adopt their identity into VM state. Without this
            // ordering, a second join request would overwrite the VM
            // fields before validation; the coordinator would then reject
            // the duplicate, leaving the VM pointing at the wrong inbox so
            // cancel()/confirmEmoji() routed to the rejected joiner.
            try await coordinator.receivedJoinRequest(joinerInboxId: joinerInboxId, deviceName: deviceName)
            let state = await coordinator.currentState
            guard case let .showingPin(pin, _, expectedJoiner) = state,
                  expectedJoiner == joinerInboxId else {
                return
            }
            // Sync the VM-side countdown with the coordinator's reset of
            // its internal expiration timer for the PIN/emoji confirmation
            // window. Without this rebase, a join request arriving late
            // in the invite window would leave the VM's countdownTask
            // firing `.expired` while the coordinator is still
            // mid-handshake.
            expiresAt = Date().addingTimeInterval(timeoutInterval)
            secondsRemaining = Int(timeoutInterval)
            joinerDeviceName = deviceName
            self.joinerInboxId = joinerInboxId
            try await pairingService.sendPinToJoiner(pin, joinerInboxId: joinerInboxId)
            flowState = .showingPin(pin: pin, deviceName: deviceName)
            startCountdown()
        } catch {
            Log.error("Pairing join request failed: \(error)")
            flowState = .failed(error.localizedDescription)
        }
    }

    func onPinEchoReceived(pin: String, from senderInboxId: String) async {
        guard let coordinator else { return }

        do {
            try await coordinator.receivedPinEcho(pin, from: senderInboxId)
            let state = await coordinator.currentState
            if case let .waitingForEmojiConfirmation(emojis, _) = state {
                // `PairingCoordinator.receivedPinEcho` resets its own
                // expiration timer for the emoji-confirmation window.
                // Rebase the VM countdown to match — otherwise the UI
                // could fire `.expired` while the user is still looking
                // at the emojis and the coordinator is mid-handshake.
                expiresAt = Date().addingTimeInterval(timeoutInterval)
                secondsRemaining = Int(timeoutInterval)
                startCountdown()
                title = "Confirm pairing"
                flowState = .emojiConfirmation(emojis: emojis, deviceName: joinerDeviceName)
            }
        } catch {
            Log.error("Pairing pin echo failed: \(error)")
            flowState = .failed(error.localizedDescription)
        }
    }

    func confirmEmoji() async {
        guard let coordinator else { return }

        countdownTask?.cancel()
        let deviceName = joinerDeviceName
        canDismiss = false
        flowState = .syncing

        do {
            try await coordinator.confirmEmoji()
            let state = await coordinator.currentState
            if case .completed = state {
                await pairingService.stop()
                if let appGroupIdentifier {
                    PairedDeviceNameStore.setPending(deviceName, appGroup: appGroupIdentifier)
                }
                NotificationCenter.default.post(
                    name: .pairingDidCompleteSuccessfully,
                    object: nil,
                    // `isInitiator` gates the post-pair profile-snapshot
                    // broadcast to the initiator side only (the joiner
                    // receives the snapshots, it doesn't re-send them).
                    userInfo: ["joinerDeviceName": deviceName, "isInitiator": true]
                )
                title = "Device added"
                flowState = .completed(deviceName: deviceName)
            } else if case let .failed(error) = state {
                await pairingService.stop()
                flowState = .failed(error.errorDescription ?? "Pairing failed")
            }
        } catch {
            Log.error("Pairing emoji confirm failed: \(error)")
            await pairingService.stop()
            flowState = .failed(error.localizedDescription)
        }
        // Always re-enable dismissal once the await completes, regardless of
        // which terminal state the coordinator landed in. Otherwise an
        // unexpected state would leave the sheet wedged open.
        canDismiss = true
    }

    func cancel() async {
        countdownTask?.cancel()
        if let coordinator, let joinerInboxId {
            let state = await coordinator.currentState
            switch state {
            case .showingPin, .waitingForEmojiConfirmation:
                await pairingService.sendPairingError(
                    to: joinerInboxId,
                    message: "Pairing was cancelled by the other device"
                )
            default:
                break
            }
        }
        await pairingService.stop()
        await coordinator?.cancel()
        coordinator = nil
    }

    func triggerConfirmEmoji() {
        Task { await confirmEmoji() }
    }

    func triggerCancel() {
        Task { await cancel() }
    }
}
