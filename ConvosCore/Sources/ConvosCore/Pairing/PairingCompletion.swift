import Foundation

public extension Notification.Name {
    /// Posted by the pairing flow after a successful pair completes on
    /// either side, so observers like `DevicesViewModel` can refresh
    /// installations (and claim any pending name). Carries a typed
    /// `PairingCompletion` payload -- read it via `Notification.pairingCompletion`.
    static let pairingDidCompleteSuccessfully: Notification.Name = Notification.Name("convos.pairing.didCompleteSuccessfully")
}

/// Which side of the pairing handshake posted the completion.
///
/// The initiator is the device that displayed the QR/PIN and adopted the
/// joiner; it carries the joiner's device name and is the only side that
/// broadcasts the post-pair profile snapshots (the joiner is the one
/// receiving them, so it must not re-send). The joiner is the device that
/// scanned in and adopted the initiator's identity.
public enum PairingRole: Sendable, Equatable {
    case initiator(joinerDeviceName: String)
    case joiner

    public var isInitiator: Bool {
        if case .initiator = self { return true }
        return false
    }

    /// The paired device's name to show optimistically in the device list.
    /// The initiator knows the joiner's name; the joiner side falls back to
    /// a generic label until the real installation row surfaces.
    public var optimisticDeviceName: String {
        switch self {
        case let .initiator(joinerDeviceName):
            return joinerDeviceName
        case .joiner:
            return "New device"
        }
    }
}

/// Typed payload for `.pairingDidCompleteSuccessfully`, replacing the prior
/// stringly-typed `userInfo` dictionary whose role was inferred from the
/// presence of an `"isInitiator"` key.
public struct PairingCompletion: Sendable, Equatable {
    public let role: PairingRole

    public init(role: PairingRole) {
        self.role = role
    }

    fileprivate static let userInfoKey: String = "convos.pairing.completion"
}

public extension NotificationCenter {
    /// Post `.pairingDidCompleteSuccessfully` carrying a typed payload.
    func postPairingCompleted(_ completion: PairingCompletion) {
        post(
            name: .pairingDidCompleteSuccessfully,
            object: nil,
            userInfo: [PairingCompletion.userInfoKey: completion]
        )
    }
}

public extension Notification {
    /// The typed pairing-completion payload, or `nil` if the notification
    /// wasn't posted with one.
    var pairingCompletion: PairingCompletion? {
        userInfo?[PairingCompletion.userInfoKey] as? PairingCompletion
    }
}
