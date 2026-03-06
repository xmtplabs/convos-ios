import Foundation

public enum PairingState: Sendable, Equatable {
    case idle
    case generatingInvite
    case waitingForScan(inviteURL: String, expiresAt: Date)
    case waitingForConfirmation(pin: String, joinerInboxId: String)
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
        case let (.waitingForConfirmation(lPin, lInbox), .waitingForConfirmation(rPin, rInbox)):
            return lPin == rPin && lInbox == rInbox
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

    public weak var delegate: (any PairingCoordinatorDelegate)?

    public var currentState: PairingState { state }

    public init(vaultManager: VaultManager, timeoutInterval: TimeInterval = 60) {
        self.vaultManager = vaultManager
        self.timeoutInterval = timeoutInterval
    }

    // MARK: - Device A: Initiate pairing

    public func startPairing(inviteURL: String) async throws {
        guard case .idle = state else {
            throw PairingError.alreadyPairing
        }

        let expiresAt = Date().addingTimeInterval(timeoutInterval)
        updateState(.waitingForScan(inviteURL: inviteURL, expiresAt: expiresAt))
        startExpirationTimer()
    }

    public func receivedJoinRequest(pin: String, joinerInboxId: String) async throws {
        guard case .waitingForScan = state else { return }

        cancelExpirationTimer()
        updateState(.waitingForConfirmation(pin: pin, joinerInboxId: joinerInboxId))
        startExpirationTimer()
    }

    public func confirmPin(_ enteredPin: String) async throws {
        guard case let .waitingForConfirmation(expectedPin, joinerInboxId) = state else {
            throw PairingError.notConnected
        }

        let cleanedInput = enteredPin.filter(\.isNumber)
        guard cleanedInput == expectedPin, cleanedInput.count == 6 else {
            throw PairingError.invalidConfirmationCode
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

    // MARK: - Device B: Generate pin

    public static func generatePin() -> String {
        (0 ..< 6).map { _ in String(Int.random(in: 0 ... 9)) }.joined()
    }

    public static func formatPin(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }

    // MARK: - Cancel

    public func cancel() {
        cancelExpirationTimer()
        updateState(.idle)
    }

    public func reset() {
        cancelExpirationTimer()
        state = .idle
    }

    // MARK: - Private

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
        guard case .waitingForScan = state else {
            guard case .waitingForConfirmation = state else { return }
            updateState(.expired)
            return
        }
        updateState(.expired)
    }

    private func cancelExpirationTimer() {
        expirationTask?.cancel()
        expirationTask = nil
    }
}
