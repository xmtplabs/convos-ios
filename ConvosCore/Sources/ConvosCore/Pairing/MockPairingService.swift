import Foundation

/// In-memory `PairingServiceProtocol` for SwiftUI previews and unit tests.
/// Records calls and returns canned values. Does not touch the keychain or
/// the network.
public final class MockPairingService: PairingServiceProtocol, @unchecked Sendable {
    public enum Behavior: Sendable {
        case success
        case throwOnSend
    }

    public var pairingInboxIdValue: String?
    public var inviteSlug: String
    public var behavior: Behavior
    public private(set) var sentJoinRequests: [(slug: String, deviceName: String)] = []
    public private(set) var sentPinsToJoiner: [(pin: String, joinerInboxId: String)] = []
    public private(set) var sentPinEchoes: [(pin: String, initiatorInboxId: String)] = []
    public private(set) var identitySharesSent: [String] = []
    public private(set) var errorsSent: [(peerInboxId: String, message: String)] = []
    public private(set) var stopCalled: Bool = false

    public private(set) var startCalled: Bool = false

    public init(
        pairingInboxId: String? = "mock-inbox",
        inviteSlug: String = "mock-slug",
        behavior: Behavior = .success
    ) {
        self.pairingInboxIdValue = pairingInboxId
        self.inviteSlug = inviteSlug
        self.behavior = behavior
    }

    public func start() async throws {
        startCalled = true
    }

    public func pairingInboxId() async -> String? {
        pairingInboxIdValue
    }

    public func createPairingInvite(expiresAt: Date) async throws -> String {
        try throwIfNeeded()
        return inviteSlug
    }

    public func sendPairingJoinRequest(slug: String, deviceName: String) async throws {
        try throwIfNeeded()
        sentJoinRequests.append((slug, deviceName))
    }

    public func sendPinToJoiner(_ pin: String, joinerInboxId: String) async throws {
        try throwIfNeeded()
        sentPinsToJoiner.append((pin, joinerInboxId))
    }

    public func sendPinEcho(_ pin: String, to initiatorInboxId: String) async throws {
        try throwIfNeeded()
        sentPinEchoes.append((pin, initiatorInboxId))
    }

    public func sendIdentityShare(toJoinerInboxId: String) async throws {
        try throwIfNeeded()
        identitySharesSent.append(toJoinerInboxId)
    }

    public func sendPairingError(to peerInboxId: String, message: String) async {
        errorsSent.append((peerInboxId, message))
    }

    public func stop() async {
        stopCalled = true
    }

    private func throwIfNeeded() throws {
        if behavior == .throwOnSend {
            throw PairingError.notConnected
        }
    }
}
