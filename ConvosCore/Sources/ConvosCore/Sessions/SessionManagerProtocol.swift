import Combine
import ConvosConnections
import Foundation

/// Progress events for inbox deletion
public enum InboxDeletionProgress: Sendable, Equatable {
    case clearingDeviceRegistration
    case stoppingServices(completed: Int, total: Int)
    case deletingFromDatabase
    case completed
}

public protocol SessionManagerProtocol: AnyObject, Sendable {
    // MARK: Inbox Management

    /// Returns the shared messaging service and an optional conversation id
    /// for a group pre-prepared by `UnusedConversationCache`. A background
    /// prewarm is kicked off for the next caller. `conversationId` is nil
    /// if no prepared group was available and the caller should create one
    /// on demand.
    func prepareNewConversation() async -> (service: AnyMessagingService, conversationId: String?)
    func deleteAllInboxes() async throws
    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error>

    // MARK: Messaging Services

    func messagingService() -> AnyMessagingService
    func messagingServiceSync() -> AnyMessagingService

    // MARK: Factory methods for repositories

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol
    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse
    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus
    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus

    func conversationRepository(for conversationId: String) -> any ConversationRepositoryProtocol

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol

    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol
    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol
    func voiceMemoTranscriptRepository() -> any VoiceMemoTranscriptRepositoryProtocol
    func voiceMemoTranscriptWriter() -> any VoiceMemoTranscriptWriterProtocol
    func voiceMemoTranscriptionService() -> any VoiceMemoTranscriptionServicing

    func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol
    func assistantFilesLinksRepository(for conversationId: String) -> AssistantFilesLinksRepository

    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol
    func conversationsCountRepo(
        for consent: [Consent],
        kinds: [ConversationKind]
    ) -> any ConversationsCountRepositoryProtocol
    func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol

    // MARK: Notifications

    func notifyChangesInDatabase()
    func shouldDisplayNotification(for conversationId: String) async -> Bool

    /// Tells the session manager whether the conversations list is currently
    /// on-screen. Used to suppress in-app notification banners — the list
    /// already surfaces the new-message indicator, so a banner would be
    /// redundant.
    func setIsOnConversationsList(_ isOn: Bool)

    /// Ensures the messaging service is ready before processing a notification
    /// for the given conversation. Safe to call from the NSE.
    func wakeInboxForNotification(conversationId: String)

    // MARK: Helpers

    func inboxId(for conversationId: String) async -> String?

    // MARK: Debug

    func pendingInviteDetails() throws -> [PendingInviteDetail]
    func deleteExpiredPendingInvites() async throws -> Int
    func isAccountOrphaned() throws -> Bool

    // MARK: Asset Renewal

    func makeAssetRenewalManager() async -> AssetRenewalManager

    // MARK: Connections

    func cloudConnectionManager(callbackURLScheme: String) -> any CloudConnectionManagerProtocol
    func cloudConnectionRepository() -> any CloudConnectionRepositoryProtocol

    // MARK: Capability resolution

    /// Session-scoped registry of `CapabilityProvider`s. Both the device subsystem
    /// (`ConvosConnections`) and the cloud subsystem (`CloudConnectionManager`) register
    /// providers here at session bootstrap and on link/unlink.
    func capabilityProviderRegistry() -> any CapabilityProviderRegistry

    /// Session-scoped capability resolver, GRDB-backed. Routes
    /// `(subject, conversation, capability)` to one or more providers per the
    /// federation rules in `CapabilityResolutionValidator`.
    func capabilityResolver() -> any CapabilityResolver

    /// Per-conversation observer that publishes the latest unresolved
    /// `capability_request`. The picker view model subscribes; recomputes its
    /// layout whenever a fresh request lands or the most recent one gets a
    /// matching result.
    func capabilityRequestRepository(for conversationId: String) -> any CapabilityRequestRepositoryProtocol

    /// Routes per-`ConnectionKind` permission prompts into ConvosConnections data
    /// sources. The picker's Connect path calls this to drive the iOS prompt without
    /// the view model having to know about HealthKit / EventKit / etc.
    func deviceConnectionAuthorizer() -> any DeviceConnectionAuthorizer

    /// Per-conversation observer of every `(subject, capability)` resolution the user
    /// has approved. Conversation Info uses this to render the "Connections" section.
    func capabilityResolutionsRepository(for conversationId: String) -> any CapabilityResolutionsRepositoryProtocol
    func connectionEnablementStore() -> any EnablementStore
}

extension SessionManagerProtocol {
    public func requestAgentJoin(slug: String, instructions: String) async throws -> ConvosAPI.AgentJoinResponse {
        try await requestAgentJoin(slug: slug, instructions: instructions, forceErrorCode: nil)
    }
}
