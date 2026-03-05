import Foundation

public enum PairingState: Sendable {
    case idle
    case waitingForScan(code: String, inviteURL: String)
    case waitingForConfirmation(code: String, joinerInboxId: String)
    case sharingKeys
    case completed(deviceCount: Int)
    case failed(any Error)
    case expired
}

public enum PairingError: Error, LocalizedError, Sendable {
    case notConnected
    case invalidConfirmationCode
    case pairingTimeout
    case alreadyPairing
    case noVaultGroup

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
        }
    }
}

public protocol PairingCoordinatorDelegate: AnyObject, Sendable {
    func pairingCoordinator(_ coordinator: PairingCoordinator, didChangeState state: PairingState)
}

public final class PairingCoordinator: Sendable {
    private let timeoutSeconds: Int

    public weak var delegate: (any PairingCoordinatorDelegate)? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    private let lock: NSLock = .init()
    private nonisolated(unsafe) weak var _delegate: (any PairingCoordinatorDelegate)?

    public init(timeoutSeconds: Int = 120) {
        self.timeoutSeconds = timeoutSeconds
    }

    public static func generateConfirmationCode() -> String {
        let code = (0 ..< 6).map { _ in String(Int.random(in: 0 ... 9)) }.joined()
        return code
    }

    public func validateConfirmationCode(_ input: String, expected: String) -> Bool {
        let cleaned = input.filter(\.isNumber)
        return cleaned == expected && cleaned.count == 6
    }
}
