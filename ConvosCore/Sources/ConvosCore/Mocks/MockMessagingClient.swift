import Foundation
@preconcurrency import XMTPiOS

// Stage 6e Phase A: minimal stub `MessagingClient` used by
// `MockXMTPClientProvider.messagingClient` so that
// `MockInboxStateManager.waitForInboxReadyResult()` can hand back an
// `InboxReadyResult` whose `.client: any MessagingClient` is non-nil
// without preconditionFailing at construction.
//
// All sub-surfaces preconditionFail on access — the existing mock
// state manager flows do not exercise them. Phase B replaces this
// stub with proper sub-surface mocks once the remaining XMTPClientProvider
// consumers are migrated.

public final class MockMessagingClient: MessagingClient, @unchecked Sendable {
    public let inboxId: MessagingInboxID
    public let installationId: MessagingInstallationID
    public let publicIdentity: MessagingIdentity

    public let conversations: any MessagingConversations
    public let consent: any MessagingConsent
    public let deviceSync: any MessagingDeviceSync
    public let installations: any MessagingInstallationsAPI

    public init(
        inboxId: MessagingInboxID = "mock-inbox-id",
        installationId: MessagingInstallationID = "mock-installation-id"
    ) {
        self.inboxId = inboxId
        self.installationId = installationId
        self.publicIdentity = MessagingIdentity(
            kind: .ethereum,
            identifier: "0x0000000000000000000000000000000000000000"
        )
        self.conversations = _StubMessagingConversations()
        self.consent = _StubMessagingConsent()
        self.deviceSync = _StubMessagingDeviceSync()
        self.installations = _StubMessagingInstallationsAPI()
    }

    // MARK: - Static construction (unused on the mock path)

    public static func create(
        signer: any MessagingSigner,
        config: MessagingClientConfig
    ) async throws -> Self {
        preconditionFailure("MockMessagingClient.create is not supported")
    }

    public static func build(
        identity: MessagingIdentity,
        inboxId: MessagingInboxID?,
        config: MessagingClientConfig
    ) async throws -> Self {
        preconditionFailure("MockMessagingClient.build is not supported")
    }

    public static func newestMessageMetadata(
        conversationIds: [String],
        config: MessagingClientConfig
    ) async throws -> [String: MessagingMessageMetadata] {
        [:]
    }

    public static func canMessage(
        identities: [MessagingIdentity],
        config: MessagingClientConfig
    ) async throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: identities.map { ($0.identifier, true) })
    }

    // MARK: - Per-instance reachability

    public func canMessage(identity: MessagingIdentity) async throws -> Bool { true }
    public func canMessage(identities: [MessagingIdentity]) async throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: identities.map { ($0.identifier, true) })
    }
    public func inboxId(for identity: MessagingIdentity) async throws -> MessagingInboxID? { nil }

    // MARK: - Signing / verification

    public func signWithInstallationKey(_ message: String) throws -> Data { Data() }
    public func verifySignature(_ message: String, signature: Data) throws -> Bool { true }
    public func verifySignature(
        _ message: String,
        signature: Data,
        installationId: MessagingInstallationID
    ) throws -> Bool { true }

    // MARK: - DB lifecycle

    public func deleteLocalDatabase() throws {}
    public func reconnectLocalDatabase() async throws {}
    public func dropLocalDatabaseConnection() throws {}
}

// MARK: - Sub-surface stubs

private final class _StubMessagingConversations: MessagingConversations, @unchecked Sendable {
    func list(query: MessagingConversationQuery) async throws -> [MessagingConversation] { [] }
    func listGroups(query: MessagingConversationQuery) async throws -> [any MessagingGroup] { [] }
    func listDms(query: MessagingConversationQuery) async throws -> [any MessagingDm] { [] }
    func find(conversationId: String) async throws -> MessagingConversation? { nil }
    func findDmByInboxId(_ inboxId: MessagingInboxID) async throws -> (any MessagingDm)? { nil }
    func findMessage(messageId: String) async throws -> MessagingMessage? { nil }
    func findOrCreateDm(with inboxId: MessagingInboxID) async throws -> any MessagingDm {
        preconditionFailure("MockMessagingClient.conversations.findOrCreateDm not supported")
    }
    func newGroupOptimistic() async throws -> any MessagingGroup {
        preconditionFailure("MockMessagingClient.conversations.newGroupOptimistic not supported")
    }
    func newGroup(
        withInboxIds inboxIds: [MessagingInboxID],
        name: String,
        imageUrl: String,
        description: String
    ) async throws -> any MessagingGroup {
        preconditionFailure("MockMessagingClient.conversations.newGroup not supported")
    }
    func sync() async throws {}
    func syncAll(consentStates: [MessagingConsentState]?) async throws -> MessagingSyncSummary {
        MessagingSyncSummary(numEligible: 0, numSynced: 0)
    }
    func streamAll(
        filter: MessagingConversationFilter,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingConversation> {
        MessagingStream { _ in }
    }
    func streamAllMessages(
        filter: MessagingConversationFilter,
        consentStates: [MessagingConsentState]?,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage> {
        MessagingStream { _ in }
    }
}

private struct _StubMessagingConsent: MessagingConsent {
    func set(records: [MessagingConsentRecord]) async throws {}
    func conversationState(id: String) async throws -> MessagingConsentState { .unknown }
    func inboxIdState(_ inboxId: MessagingInboxID) async throws -> MessagingConsentState { .unknown }
    func syncPreferences() async throws {}
}

private struct _StubMessagingDeviceSync: MessagingDeviceSync {
    func sendSyncRequest(options: MessagingArchiveOptions, serverUrl: String?) async throws {}
    func sendSyncArchive(options: MessagingArchiveOptions, serverUrl: String?, pin: String) async throws {}
    func processSyncArchive(pin: String?) async throws {}
    func syncAllDeviceSyncGroups() async throws -> MessagingSyncSummary {
        MessagingSyncSummary(numEligible: 0, numSynced: 0)
    }
    func createArchive(path: String, encryptionKey: Data, options: MessagingArchiveOptions) async throws {}
    func importArchive(path: String, encryptionKey: Data) async throws {}
}

private struct _StubMessagingInstallationsAPI: MessagingInstallationsAPI {
    func inboxState(refreshFromNetwork: Bool) async throws -> MessagingInbox {
        preconditionFailure("MockMessagingClient.installations.inboxState not supported")
    }
    func inboxStates(
        inboxIds: [MessagingInboxID],
        refreshFromNetwork: Bool
    ) async throws -> [MessagingInbox] { [] }
    func revokeInstallations(
        signer: any MessagingSigner,
        installationIds: [MessagingInstallationID]
    ) async throws {}
    func revokeAllOtherInstallations(signer: any MessagingSigner) async throws {}
    static func revokeInstallations(
        config: MessagingClientConfig,
        signer: any MessagingSigner,
        inboxId: MessagingInboxID,
        installationIds: [MessagingInstallationID]
    ) async throws {}
}
