import CryptoKit
import Foundation

public enum PairingState: Sendable, Equatable {
    case idle
    case generatingInvite
    case waitingForScan(inviteURL: String, expiresAt: Date)
    case showingPin(pin: String, deviceName: String, joinerInboxId: String)
    case waitingForEmojiConfirmation(emojis: [String], joinerInboxId: String)
    case addingDevice
    case sharingKeys
    case completed(deviceCount: Int)
    case failed(PairingError)
    case expired

    public static func == (lhs: PairingState, rhs: PairingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.generatingInvite, .generatingInvite),
             (.addingDevice, .addingDevice),
             (.sharingKeys, .sharingKeys),
             (.expired, .expired):
            return true
        case let (.waitingForScan(lURL, lExp), .waitingForScan(rURL, rExp)):
            return lURL == rURL && lExp == rExp
        case let (.showingPin(lPin, lName, lInbox), .showingPin(rPin, rName, rInbox)):
            return lPin == rPin && lName == rName && lInbox == rInbox
        case let (.waitingForEmojiConfirmation(lEmojis, lInbox), .waitingForEmojiConfirmation(rEmojis, rInbox)):
            return lEmojis == rEmojis && lInbox == rInbox
        case let (.completed(lCount), .completed(rCount)):
            return lCount == rCount
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
    case noVaultGroup
    case invalidInviteSlug
    case addMemberFailed(String)
    case shareKeysFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Vault is not connected"
        case .invalidConfirmationCode:
            return "The confirmation code does not match"
        case .pairingTimeout:
            return "Pairing timed out"
        case .alreadyPairing:
            return "A pairing session is already in progress"
        case .noVaultGroup:
            return "No vault group found"
        case .invalidInviteSlug:
            return "Invalid pairing invite"
        case let .addMemberFailed(reason):
            return "Failed to add device: \(reason)"
        case let .shareKeysFailed(reason):
            return "Failed to share keys: \(reason)"
        }
    }
}

public protocol PairingCoordinatorDelegate: AnyObject, Sendable {
    func pairingCoordinator(_ coordinator: PairingCoordinator, didChangeState state: PairingState)
}

public actor PairingCoordinator {
    private let vaultManager: VaultManager
    private let timeoutInterval: TimeInterval
    private var state: PairingState = .idle
    private var expirationTask: Task<Void, Never>?
    private var generatedPin: String?
    private var initiatorInboxId: String?

    public weak var delegate: (any PairingCoordinatorDelegate)?

    public var currentState: PairingState { state }

    public init(vaultManager: VaultManager, timeoutInterval: TimeInterval = 60) {
        self.vaultManager = vaultManager
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
    }

    public func confirmEmoji() async throws {
        guard case let .waitingForEmojiConfirmation(_, joinerInboxId) = state else {
            throw PairingError.notConnected
        }

        cancelExpirationTimer()

        updateState(.addingDevice)
        do {
            try await vaultManager.addMember(inboxId: joinerInboxId)
        } catch {
            let pairingError = PairingError.addMemberFailed(error.localizedDescription)
            await vaultManager.sendPairingError(to: joinerInboxId, message: pairingError.errorDescription ?? "Failed to add device")
            updateState(.failed(pairingError))
            return
        }

        updateState(.sharingKeys)
        do {
            try await vaultManager.shareAllKeys()
        } catch {
            let pairingError = PairingError.shareKeysFailed(error.localizedDescription)
            await vaultManager.sendPairingError(to: joinerInboxId, message: pairingError.errorDescription ?? "Failed to share keys")
            updateState(.failed(pairingError))
            return
        }

        let deviceCount = (try? await vaultManager.listDevices().count) ?? 2
        updateState(.completed(deviceCount: deviceCount))
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
        state = .idle
    }

    private func updateState(_ newState: PairingState) {
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
