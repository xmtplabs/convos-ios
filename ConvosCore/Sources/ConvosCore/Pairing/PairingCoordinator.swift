import CryptoKit
import Foundation

public enum PairingState: Sendable, Equatable {
    case idle
    case generatingInvite
    case waitingForScan(inviteURL: String, expiresAt: Date)
    case showingPin(pin: String, deviceName: String, joinerInboxId: String)
    case waitingForEmojiConfirmation(emojis: [String], joinerInboxId: String)
    case sharingIdentity
    case completed
    case failed(PairingError)
    case expired

    public static func == (lhs: PairingState, rhs: PairingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.generatingInvite, .generatingInvite),
             (.sharingIdentity, .sharingIdentity),
             (.completed, .completed),
             (.expired, .expired):
            return true
        case let (.waitingForScan(lURL, lExp), .waitingForScan(rURL, rExp)):
            return lURL == rURL && lExp == rExp
        case let (.showingPin(lPin, lName, lInbox), .showingPin(rPin, rName, rInbox)):
            return lPin == rPin && lName == rName && lInbox == rInbox
        case let (.waitingForEmojiConfirmation(lEmojis, lInbox), .waitingForEmojiConfirmation(rEmojis, rInbox)):
            return lEmojis == rEmojis && lInbox == rInbox
        case let (.failed(lErr), .failed(rErr)):
            return lErr == rErr
        default:
            return false
        }
    }
}

public enum PairingError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case invalidConfirmationCode
    case pairingTimeout
    case alreadyPairing
    case invalidInviteSlug
    case addressMismatch
    case identityShareSendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Pairing is not connected"
        case .invalidConfirmationCode:
            return "The confirmation code does not match"
        case .pairingTimeout:
            return "Pairing timed out"
        case .alreadyPairing:
            return "A pairing session is already in progress"
        case .invalidInviteSlug:
            return "Invalid pairing invite"
        case .addressMismatch:
            return "Identity mismatch"
        case let .identityShareSendFailed(reason):
            return "Failed to share identity: \(reason)"
        }
    }
}

public protocol PairingCoordinatorDelegate: AnyObject, Sendable {
    func pairingCoordinator(_ coordinator: PairingCoordinator, didChangeState state: PairingState)
}

public actor PairingCoordinator {
    private let pairingService: any PairingServiceProtocol
    private let timeoutInterval: TimeInterval
    private var state: PairingState = .idle
    private var expirationTask: Task<Void, Never>?
    private var generatedPin: String?
    private var initiatorInboxId: String?

    public weak var delegate: (any PairingCoordinatorDelegate)?

    public var currentState: PairingState { state }

    public init(pairingService: any PairingServiceProtocol, timeoutInterval: TimeInterval = 60) {
        self.pairingService = pairingService
        self.timeoutInterval = timeoutInterval
    }

    public func startPairing(inviteURL: String, initiatorInboxId: String) async throws {
        guard case .idle = state else {
            throw PairingError.alreadyPairing
        }

        self.initiatorInboxId = initiatorInboxId
        let expiresAt = Date().addingTimeInterval(timeoutInterval)
        updateState(.waitingForScan(inviteURL: inviteURL, expiresAt: expiresAt))
        startExpirationTimer()
    }

    public func receivedJoinRequest(joinerInboxId: String, deviceName: String) async throws {
        guard case .waitingForScan = state else { return }

        cancelExpirationTimer()
        let pin = Self.generatePin()
        generatedPin = pin
        updateState(.showingPin(pin: pin, deviceName: deviceName, joinerInboxId: joinerInboxId))
        startExpirationTimer()
    }

    public func receivedPinEcho(_ echoedPin: String, from joinerInboxId: String) async throws {
        guard case let .showingPin(_, _, expectedJoiner) = state else {
            throw PairingError.notConnected
        }
        guard joinerInboxId == expectedJoiner else { return }
        guard let generatedPin, echoedPin == generatedPin else {
            throw PairingError.invalidConfirmationCode
        }

        cancelExpirationTimer()
        guard let initiatorInboxId else { throw PairingError.notConnected }
        let emojis = Self.emojiFingerprint(inboxA: initiatorInboxId, inboxB: joinerInboxId, pin: generatedPin)
        updateState(.waitingForEmojiConfirmation(emojis: emojis, joinerInboxId: joinerInboxId))
        // Restart the timer for the emoji-confirmation phase — handleExpiration
        // explicitly handles this state, but without the restart the coordinator
        // would sit in `.waitingForEmojiConfirmation` forever if the user never
        // taps confirm. receivedJoinRequest does the same after its transition.
        startExpirationTimer()
    }

    public func confirmEmoji() async throws {
        guard case let .waitingForEmojiConfirmation(_, joinerInboxId) = state else {
            throw PairingError.notConnected
        }

        cancelExpirationTimer()
        updateState(.sharingIdentity)

        do {
            try await pairingService.sendIdentityShare(toJoinerInboxId: joinerInboxId)
        } catch {
            let pairingError = PairingError.identityShareSendFailed(error.localizedDescription)
            await pairingService.sendPairingError(
                to: joinerInboxId,
                message: pairingError.errorDescription ?? "Failed to share identity"
            )
            updateState(.failed(pairingError))
            return
        }

        updateState(.completed)
    }

    public static func generatePin() -> String {
        (0 ..< 6).map { _ in String(Int.random(in: 0 ... 9)) }.joined()
    }

    public static func formatPin(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }

    public static func emojiFingerprint(inboxA: String, inboxB: String, pin: String) -> [String] {
        let inputs = [inboxA, inboxB].sorted()
        let combined = inputs.joined(separator: ":") + ":" + pin
        let hash = SHA256.hash(data: Data(combined.utf8))
        let bytes = Array(hash)
        let emojiCount = EmojiSelector.emojis.count
        return (0 ..< 3).map { i in
            EmojiSelector.emojis[Int(bytes[i]) % emojiCount]
        }
    }

    public func cancel() {
        cancelExpirationTimer()
        generatedPin = nil
        initiatorInboxId = nil
        updateState(.idle)
    }

    public func reset() {
        cancelExpirationTimer()
        generatedPin = nil
        initiatorInboxId = nil
        updateState(.idle)
    }

    private func updateState(_ newState: PairingState) {
        ConvosLog.info("PairingCoordinator state: \(state) -> \(newState)", namespace: "ConvosCore.Pairing")
        state = newState
        delegate?.pairingCoordinator(self, didChangeState: newState)
    }

    private func startExpirationTimer() {
        cancelExpirationTimer()
        let timeout = timeoutInterval
        expirationTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            handleExpiration()
        }
    }

    private func handleExpiration() {
        switch state {
        case .waitingForScan, .showingPin, .waitingForEmojiConfirmation:
            ConvosLog.warning("PairingCoordinator expired in state: \(state)", namespace: "ConvosCore.Pairing")
            updateState(.expired)
        default:
            break
        }
    }

    private func cancelExpirationTimer() {
        expirationTask?.cancel()
        expirationTask = nil
    }
}
