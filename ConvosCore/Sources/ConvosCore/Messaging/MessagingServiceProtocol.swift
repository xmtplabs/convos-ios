import Combine
import ConvosConnections
import Foundation

public enum MessagingServiceState {
    case registering, authorized(String)
}

extension MessagingServiceProtocol {
    public var state: MessagingServiceState {
        switch sessionStateManager.currentState {
        case .ready(let result):
            return .authorized(result.client.inboxId)
        default:
            return .registering
        }
    }

    /// Default forwards to the existing zero-arg factory when no initial
    /// members were supplied so existing conformers (mocks, tests) keep
    /// working without recompiling. Concrete services (`MessagingService`)
    /// override to actually thread the ids through
    /// `ConversationStateManager.init`.
    public func conversationStateManager(
        initialMemberInboxIds: [String]
    ) -> any ConversationStateManagerProtocol {
        conversationStateManager()
    }

    public func conversationStateManager(
        for conversationId: String,
        initialMemberInboxIds: [String]
    ) -> any ConversationStateManagerProtocol {
        conversationStateManager(for: conversationId)
    }
}

public protocol MessagingServiceProtocol: AnyObject, Sendable, PostPairBroadcastMessaging {
    var state: MessagingServiceState { get }
    var sessionStateManager: any SessionStateManagerProtocol { get }

    func stop()
    func stop() async
    func stopAndDelete()
    func stopAndDelete() async
    func waitForDeletionComplete() async

    func myProfileWriter() -> any MyProfileWriterProtocol
    func myGlobalProfileWriter() -> any MyGlobalProfileWriterProtocol
    func myGlobalProfileRepository() -> any MyGlobalProfileRepositoryProtocol

    func conversationStateManager() -> any ConversationStateManagerProtocol
    func conversationStateManager(for conversationId: String) -> any ConversationStateManagerProtocol
    /// Same as `conversationStateManager()` but the state manager seeds
    /// its state machine with `initialMemberInboxIds` so the create
    /// sequence runs the addMembers hook atomically before `.ready`. Used
    /// by the contacts picker "Start Conversation" flow. Defaulted on the
    /// extension above to preserve binary compatibility with existing
    /// conformers.
    func conversationStateManager(initialMemberInboxIds: [String]) -> any ConversationStateManagerProtocol
    /// Same as `conversationStateManager(for:)` but the state manager
    /// seeds its state machine with `initialMemberInboxIds`. The
    /// warm-cache path uses this when picker-flow members must be folded
    /// into a pre-prepared conversation before `.ready`.
    func conversationStateManager(
        for conversationId: String,
        initialMemberInboxIds: [String]
    ) -> any ConversationStateManagerProtocol

    func conversationConsentWriter() -> any ConversationConsentWriterProtocol
    func conversationLocalStateWriter() -> any ConversationLocalStateWriterProtocol

    func messageWriter(
        for conversationId: String,
        backgroundUploadManager: any BackgroundUploadManagerProtocol
    ) -> any OutgoingMessageWriterProtocol
    func reactionWriter() -> any ReactionWriterProtocol
    func readReceiptWriter() -> any ReadReceiptWriterProtocol
    func replyWriter() -> any ReplyMessageWriterProtocol

    func conversationMetadataWriter() -> any ConversationMetadataWriterProtocol
    func conversationExplosionWriter() -> any ConversationExplosionWriterProtocol
    func conversationPermissionsRepository() -> any ConversationPermissionsRepositoryProtocol
    func connectionGrantWriter() -> any CloudConnectionGrantWriterProtocol
    func connectionServicesStore() -> any ConnectionServicesStoreProtocol
    func connectionEventWriter() -> any ConnectionEventWriterProtocol
    func capabilityRequestResultWriter() -> any CapabilityRequestResultWriterProtocol

    // MARK: Contacts

    func contactsRepository() -> any ContactsRepositoryProtocol
    func contactsWriter() -> any ContactsWriterProtocol
    func contactSyncCoordinator() -> any ContactSyncCoordinatorProtocol

    func uploadImage(data: Data, filename: String) async throws -> String
    func uploadImageAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String

    func setConversationNotificationsEnabled(_ enabled: Bool, for conversationId: String) async throws
    func sendTypingIndicator(isTyping: Bool, for conversationId: String) async throws

    /// Sends a `convos.org/thinking-control:1.0` message asking `agentInboxId`
    /// to stop or resume the thinking session anchored to `targetMessageId`
    /// (a UI-level message id; resolved to the wire id before sending), and
    /// persists the action locally so the detail sheet's button flips
    /// immediately.
    func sendThinkingControl(
        action: ThinkingControlAction,
        targetMessageId: String,
        agentInboxId: String,
        for conversationId: String
    ) async throws

    /// Injection point used by the in-app debug attachment tool to dispatch a synthesized
    /// `ConnectionPayload` (e.g. a fake HealthKit background update) to a conversation.
    /// Mirrors what `HealthBackgroundObserverRoutine` would send when a real observer
    /// fires, so the agent's incoming-payload handler can be exercised end-to-end. The UI
    /// entry point is `#if DEBUG`-gated in the main app target.
    func sendDebugConnectionPayload(_ payload: ConnectionPayload, to conversationId: String) async throws

    /// Returns an initiator-side `PairingServiceProtocol` backed by this
    /// inbox's real XMTP client. Used by the "Add new device" flow in
    /// Settings → Devices. Throws if the inbox isn't ready yet (e.g. the
    /// state machine is still authorizing).
    func initiatorPairingService() async throws -> any PairingServiceProtocol

    /// Snapshot of the inbox's libxmtp installations (this device plus
    /// any other paired devices). The Devices screen drives off this.
    /// (`installationsSnapshot` + `broadcastProfileSnapshotsToAllGroups`
    /// are inherited from `PostPairBroadcastMessaging`.)

    /// Revokes every installation other than this device's own. Used by
    /// "Sign out other devices". Returns the installationIds revoked.
    func revokeOtherInstallations() async throws -> [String]

    /// Revokes a single named installation. Used by the per-row "Delete"
    /// affordance in Devices. Throws if the id is the current device.
    func revokeInstallation(installationId: String) async throws
}
