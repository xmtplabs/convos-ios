import Foundation

public extension Notification.Name {
    /// Posted by the joiner-side PairingService when the initiator's PIN
    /// arrives. `userInfo` contains `pin: String` and `initiatorInboxId: String`.
    static let pairingDidReceivePin = Notification.Name("convos.pairing.didReceivePin")

    /// Posted by the joiner-side PairingService when the initiator's
    /// IdentityShare DM arrives and has been validated. The actual save
    /// happens in PairingService before this notification fires.
    /// `userInfo` contains `inboxId: String`.
    static let pairingDidReceiveIdentityShare = Notification.Name("convos.pairing.didReceiveIdentityShare")

    /// Posted by either side when an error DM is received from the peer.
    /// `userInfo` contains `message: String`.
    static let pairingDidReceiveError = Notification.Name("convos.pairing.didReceiveError")

    /// Posted by the initiator-side PairingService when a joiner sends
    /// a `PairingJoinRequest` DM. `userInfo` contains `joinerInboxId: String`,
    /// `deviceName: String`, and `slug: String`.
    static let pairingDidReceiveJoinRequest = Notification.Name("convos.pairing.didReceiveJoinRequest")

    /// Posted by the initiator-side PairingService when the joiner echoes
    /// the PIN back. `userInfo` contains `pin: String` and `joinerInboxId: String`.
    static let pairingDidReceivePinEcho = Notification.Name("convos.pairing.didReceivePinEcho")
}

/// Carried in `PairingService.pairingJoinRequestStream` for the initiator
/// to surface to the coordinator.
public struct PairingJoinRequest: Sendable, Equatable {
    public let joinerInboxId: String
    public let deviceName: String
    public let slug: String

    public init(joinerInboxId: String, deviceName: String, slug: String) {
        self.joinerInboxId = joinerInboxId
        self.deviceName = deviceName
        self.slug = slug
    }
}

/// Carried in `PairingService.pinEchoStream` for the initiator to surface
/// to the coordinator.
public struct PairingPinEcho: Sendable, Equatable {
    public let pin: String
    public let joinerInboxId: String

    public init(pin: String, joinerInboxId: String) {
        self.pin = pin
        self.joinerInboxId = joinerInboxId
    }
}

/// Protocol used by `PairingCoordinator` and the pairing sheets. Concrete
/// implementation lives in `LivePairingService` (initiator side, backed by
/// the user's real XMTP client) and `JoinerPairingService` (joiner side,
/// backed by an ephemeral XMTP client created just for the handshake).
public protocol PairingServiceProtocol: AnyObject, Sendable {
    /// Starts the underlying DM stream. Joiner side: also builds the
    /// ephemeral XMTP client. Idempotent — safe to call more than once.
    func start() async throws

    /// Returns the inbox id used for pairing DMs. For the initiator this is
    /// the user's real inbox; for the joiner this is the ephemeral inbox
    /// created at startup.
    func pairingInboxId() async -> String?

    /// Initiator side: create a `SignedInvite`-style slug. Returns
    /// the URL-safe slug. The caller composes the full URL.
    func createPairingInvite(expiresAt: Date) async throws -> String

    /// Joiner side: send a join request DM to the initiator's inbox.
    /// Returns when the DM has been sent (not when it's been processed by
    /// the initiator).
    func sendPairingJoinRequest(slug: String, deviceName: String) async throws

    /// Initiator side: send the PIN to the joiner's ephemeral inbox.
    func sendPinToJoiner(_ pin: String, joinerInboxId: String) async throws

    /// Joiner side: send the typed PIN back to the initiator's inbox.
    func sendPinEcho(_ pin: String, to initiatorInboxId: String) async throws

    /// Initiator side: send the IdentityShare DM to the joiner. Called by
    /// the coordinator after the user confirms the emoji fingerprint.
    /// `LivePairingService` reads its own `KeychainIdentity` and packages
    /// `IdentityShareContent` from it.
    func sendIdentityShare(toJoinerInboxId: String) async throws

    /// Either side: send a `PairingMessageContent.error` DM so the peer
    /// sees a failure state instead of waiting.
    func sendPairingError(to peerInboxId: String, message: String) async

    /// Tear down DM streams and (joiner side) the ephemeral XMTP client.
    func stop() async
}
