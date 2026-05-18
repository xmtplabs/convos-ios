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

public protocol MessagingServiceProtocol: AnyObject, Sendable {
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

    /// Injection point used by the in-app debug attachment tool to dispatch a synthesized
    /// `ConnectionPayload` (e.g. a fake HealthKit background update) to a conversation.
    /// Mirrors what `HealthBackgroundObserverRoutine` would send when a real observer
    /// fires, so the agent's incoming-payload handler can be exercised end-to-end. The UI
    /// entry point is `#if DEBUG`-gated in the main app target.
    func sendDebugConnectionPayload(_ payload: ConnectionPayload, to conversationId: String) async throws

    /// Returns the current device's inbox state — installation id, inbox id, and every
    /// installation the network reports for this inbox. Used by the debug menu to show
    /// whether the device has hit the 10-installation cap.
    func installationsSnapshot(refreshFromNetwork: Bool) async throws -> InstallationsSnapshot

    /// Revokes every installation registered to this inbox except the one currently
    /// active on this device. Returns the ids that were revoked. Used to recover from
    /// the 10-installation cap after wipe-and-reinstall cycles accumulate stale entries.
    func revokeOtherInstallations() async throws -> [String]
}
