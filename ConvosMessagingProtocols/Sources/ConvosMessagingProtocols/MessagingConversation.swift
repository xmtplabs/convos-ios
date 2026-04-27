import Foundation

// MARK: - Conversation enum

/// Convos-owned replacement for `XMTPiOS.Conversation`.
///
/// The enum shape is preserved deliberately: Convos pattern-matches
/// on `.group(...) / .dm(...)` throughout sync (see
/// `StreamProcessor.swift:187`, `ConversationWriter`, etc.).
public enum MessagingConversation: Identifiable, Sendable {
    case group(any MessagingGroup)
    case dm(any MessagingDm)

    public var id: String {
        switch self {
        case .group(let group):
            return group.id
        case .dm(let dm):
            return dm.id
        }
    }

    /// Convenience accessor matching the `MessagingConversationCore`
    /// surface for call sites that do not care which case they have.
    public var core: any MessagingConversationCore {
        switch self {
        case .group(let group):
            return group
        case .dm(let dm):
            return dm
        }
    }
}

// MARK: - Core conversation surface

/// Fields and operations common to both `MessagingGroup` and
/// `MessagingDm`.
///
/// The method signatures are chosen to preserve the three distinct
/// send flows called out in audit §3:
///
/// 1. `prepare` — `XMTPiOS.Conversation.prepareMessage(noSend: true)`.
///    Stores locally as `.unpublished`; no network I/O.
/// 2. `sendOptimistic` — `prepareMessage(noSend: false)`. Stores
///    locally and best-effort publishes.
/// 3. `publish` / `publish(messageId:)` — publishes all pending
///    messages or exactly one, respectively.
public protocol MessagingConversationCore: AnyObject, Sendable {
    var id: String { get }
    var topic: String { get }
    var createdAtNs: Int64 { get }
    var lastActivityAtNs: Int64 { get }

    func consentState() async throws -> MessagingConsentState
    func updateConsentState(_ state: MessagingConsentState) async throws

    /// Returns a plain-values snapshot of the current MLS epoch /
    /// commit-log / fork state for this conversation. See
    /// `MessagingConversationDebugInfo` for the field list.
    ///
    /// The return type is deliberately a value struct of primitives
    /// (no protobuf, no SDK handle) so the DTU adapter can construct
    /// it without linking the XMTPiOS wire layer.
    func debugInformation() async throws -> MessagingConversationDebugInfo

    func sync() async throws

    func members() async throws -> [MessagingMember]

    func messages(query: MessagingMessageQuery) async throws -> [MessagingMessage]
    func lastMessage() async throws -> MessagingMessage?
    func countMessages(query: MessagingMessageQuery) async throws -> Int64

    /// Stream new messages for this conversation.
    ///
    /// Returns `MessagingStream<MessagingMessage>`, which is a typealias
    /// for `AsyncThrowingStream` under the hood (see
    /// `MessagingStream.swift`).
    func streamMessages(
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage>

    // Multi-installation: expose HMAC / push topics so device-sync work
    // does not need another API change.
    func getHmacKeys() async throws -> MessagingHmacKeys
    func getPushTopics() async throws -> [String]

    /// Decrypt and decode a raw wire-format push payload.
    /// Returns `nil` when the bytes don't resolve to a message.
    func processMessage(bytes: Data) async throws -> MessagingMessage?

    // MARK: Send flows

    /// Prepare-only send. Stores locally, delivery status
    /// `.unpublished`, does not attempt network publish.
    func prepare(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage

    /// Optimistic send. Stores locally and best-effort publishes
    /// (maps to `prepareMessage(noSend: false)`).
    @discardableResult
    func sendOptimistic(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage

    /// Publishes every unpublished message for this conversation.
    func publish() async throws

    /// Publishes exactly one prepared message by id.
    func publish(messageId: String) async throws
}

// MARK: - Group

/// Group-conversation surface.
///
/// All methods map 1:1 to operations Convos already calls on
/// `XMTPiOS.Group`, including the `appData()` / `updateAppData(_:)`
/// pair that is the backbone of `XMTPGroup+CustomMetadata.swift`
/// (the 342-line invite/metadata engine called out in audit §1.2).
public protocol MessagingGroup: MessagingConversationCore {
    func name() async throws -> String
    func imageUrl() async throws -> String
    func description() async throws -> String

    /// Convos-specific 8 KB protobuf blob. See audit open question #5
    /// for the DTU commit-log ordering constraint this relies on.
    func appData() async throws -> String
    func updateAppData(_ appData: String) async throws

    func updateName(_ name: String) async throws
    func updateImageUrl(_ url: String) async throws
    func updateDescription(_ description: String) async throws

    func addMembers(inboxIds: [MessagingInboxID]) async throws
    func removeMembers(inboxIds: [MessagingInboxID]) async throws

    func permissionPolicySet() async throws -> MessagingPermissionPolicySet
    func updateAddMemberPermission(_ permission: MessagingPermission) async throws

    func creatorInboxId() async throws -> MessagingInboxID
    func isCreator() async throws -> Bool
    func isAdmin(inboxId: MessagingInboxID) async throws -> Bool
    func isSuperAdmin(inboxId: MessagingInboxID) async throws -> Bool
    func listAdmins() async throws -> [MessagingInboxID]
    func listSuperAdmins() async throws -> [MessagingInboxID]
    func isActive() async throws -> Bool

    // Admin-management methods consumed by
    // `ConversationMetadataWriter`. Mirror the `XMTPiOS.Group`
    // `addAdmin(inboxId:)` / `removeAdmin(inboxId:)` /
    // `addSuperAdmin(inboxId:)` / `removeSuperAdmin(inboxId:)` surface.
    func addAdmin(inboxId: MessagingInboxID) async throws
    func removeAdmin(inboxId: MessagingInboxID) async throws
    func addSuperAdmin(inboxId: MessagingInboxID) async throws
    func removeSuperAdmin(inboxId: MessagingInboxID) async throws
}

// MARK: - DM

/// Direct-message surface.
///
/// The DM back-channel is load-bearing for invite flows
/// (`InviteJoinRequestsManager.swift:52`) — see audit open question #4.
public protocol MessagingDm: MessagingConversationCore {
    func peerInboxId() async throws -> MessagingInboxID
}

// MARK: - Debug info

/// Fork-status classification for an MLS commit log. Mirrors the
/// three-value enum surfaced by the XMTPiOS SDK, but lives on the
/// abstraction side so the debug surface does not leak SDK types.
public enum MessagingCommitLogForkStatus: String, Hashable, Sendable, Codable {
    case forked
    case notForked = "not_forked"
    case unknown
}

/// Plain-values snapshot of the current MLS epoch / commit-log /
/// fork state for a single conversation.
///
/// All fields are primitives (`UInt64` / `Bool` / `String` /
/// `MessagingCommitLogForkStatus`) so adapters can populate this
/// without linking any wire-format protobuf. Callers are free to
/// serialise it (see `MessagingConversation.exportDebugLogs()` and
/// `Storage/Writers/ConversationWriter.swift`).
public struct MessagingConversationDebugInfo: Hashable, Sendable, Codable {
    public let epoch: UInt64
    public let maybeForked: Bool
    public let forkDetails: String
    public let localCommitLog: String
    public let remoteCommitLog: String
    public let commitLogForkStatus: MessagingCommitLogForkStatus

    public init(
        epoch: UInt64,
        maybeForked: Bool,
        forkDetails: String,
        localCommitLog: String,
        remoteCommitLog: String,
        commitLogForkStatus: MessagingCommitLogForkStatus
    ) {
        self.epoch = epoch
        self.maybeForked = maybeForked
        self.forkDetails = forkDetails
        self.localCommitLog = localCommitLog
        self.remoteCommitLog = remoteCommitLog
        self.commitLogForkStatus = commitLogForkStatus
    }
}

// MARK: - Debug export

/// Default `exportDebugLogs()` implementation that writes a
/// JSON file to the temp directory and returns its URL. Every
/// conformer gets this for free; adapters only need to implement
/// `debugInformation()`.
public extension MessagingConversation {
    func exportDebugLogs() async throws -> URL {
        let debugInfo = try await core.debugInformation()
        let payload: [String: Any] = [
            "conversationId": id,
            "epoch": debugInfo.epoch,
            "maybeForked": debugInfo.maybeForked,
            "forkDetails": debugInfo.forkDetails,
            "localCommitLog": debugInfo.localCommitLog,
            "remoteCommitLog": debugInfo.remoteCommitLog,
            "commitLogForkStatus": String(describing: debugInfo.commitLogForkStatus)
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tempDir = FileManager.default.temporaryDirectory
        let safeId = id.replacingOccurrences(of: "/", with: "_")
        let fileName = "conversation-\(safeId)-debug-\(Date().timeIntervalSince1970).json"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try jsonData.write(to: fileURL)
        return fileURL
    }
}
