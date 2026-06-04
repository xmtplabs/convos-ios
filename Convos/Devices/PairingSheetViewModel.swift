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

/// How the initiator pairing sheet was entered.
enum PairingSheetMode: Equatable {
    /// Settings > Devices > Add new device: create an invite and show
    /// the QR for a joiner to scan.
    case createInvite
    /// A verified join request already arrived via the main message
    /// stream (iCloud-discovery joiner); respond with a PIN immediately,
    /// no QR step.
    case respondToJoinRequest(joinerInboxId: String, deviceName: String)
}

@Observable
@MainActor
final class PairingSheetViewModel: Identifiable {
    /// The initiator sheet currently mid-flow, if any. Weak so dismissal
    /// (either host nils its reference) clears it automatically. The
    /// auto-surface path checks this to avoid presenting a second
    /// initiator flow - two coordinators would race PIN generation for
    /// the same joiner and the handshake would fail on a stale PIN.
    private(set) static weak var active: PairingSheetViewModel?

    var flowState: PairingFlowState = .qrCode(url: "")
    var canDismiss: Bool = true
    var title: String = "Pair new device"
    var secondsRemaining: Int = 60

    private let pairingService: any PairingServiceProtocol
    private let appGroupIdentifier: String?
    private let timeoutInterval: TimeInterval
    private let mode: PairingSheetMode
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
        mode: PairingSheetMode = .createInvite,
        appGroupIdentifier: String? = nil
    ) {
        self.pairingService = pairingService
        self.appGroupIdentifier = appGroupIdentifier
        self.timeoutInterval = timeoutInterval
        self.mode = mode
        self.secondsRemaining = Int(timeoutInterval)
        self.observers = PairingNotificationObservers()
        if case .respondToJoinRequest = mode {
            // Respond mode never shows a QR; start in the spinner state
            // so the sheet doesn't flash the empty QR layout while the
            // pairing service bootstraps toward `.showingPin`.
            self.flowState = .syncing
        }
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
        Self.active = self
        switch mode {
        case .createInvite:
            await startInviteFlow()
        case let .respondToJoinRequest(joinerInboxId, deviceName):
            await startRespondFlow(joinerInboxId: joinerInboxId, deviceName: deviceName)
        }
    }

    private func startInviteFlow() async {
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
            // The service may have started before the failing call; stop
            // it so its stream doesn't outlive the failed flow (mirrors
            // confirmEmoji's failure handling).
            await pairingService.stop()
            flowState = .failed(error.localizedDescription)
        }
    }

    /// Mirrors the back half of `onJoinRequestReceived`: the join request
    /// already arrived (verified by the stream layer), so the coordinator
    /// starts directly in `.showingPin` and the PIN goes straight to the
    /// joiner.
    private func startRespondFlow(joinerInboxId: String, deviceName: String) async {
        let coordinator = PairingCoordinator(pairingService: pairingService, timeoutInterval: timeoutInterval)
        self.coordinator = coordinator

        do {
            try await pairingService.start()
            guard let initiatorInboxId = await pairingService.pairingInboxId() else {
                await pairingService.stop()
                flowState = .failed("Pairing service is not ready")
                return
            }
            let pin = try await coordinator.startPairing(
                respondingToJoinerInboxId: joinerInboxId,
                deviceName: deviceName,
                initiatorInboxId: initiatorInboxId
            )
            joinerDeviceName = deviceName
            self.joinerInboxId = joinerInboxId
            expiresAt = Date().addingTimeInterval(timeoutInterval)
            secondsRemaining = Int(timeoutInterval)
            try await pairingService.sendPinToJoiner(pin, joinerInboxId: joinerInboxId)
            QAEvent.emit(.pairing, "responding_to_join_request", ["joinerInboxId": joinerInboxId])
            flowState = .showingPin(pin: pin, deviceName: deviceName)
            startCountdown()
        } catch {
            Log.error("Pairing respond flow failed: \(error)")
            // Mirrors confirmEmoji's failure handling: the service was
            // started above, so stop its stream before parking in .failed.
            await pairingService.stop()
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
                // `.initiator` gates the post-pair profile-snapshot broadcast
                // to the initiator side only (the joiner receives the
                // snapshots, it doesn't re-send them).
                NotificationCenter.default.postPairingCompleted(
                    PairingCompletion(role: .initiator(joinerDeviceName: deviceName))
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
