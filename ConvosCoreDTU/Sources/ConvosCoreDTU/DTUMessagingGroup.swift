import ConvosCore
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingGroup`.
///
/// Holds the DTU universe + actor context plus the conversation alias
/// returned by DTU's `create_group` action (e.g. `g1`). All method calls
/// dispatch actions against the universe tagged with the actor alias.
///
/// The DTU engine exposes a narrower surface than XMTPiOS:
///  - Metadata (name / description / image / appData) is NOT modeled in
///    the current engine. Getters return empty strings; setters throw
///    `DTUMessagingNotSupportedError`.
///  - HMAC keys and push topics are NOT in the engine (they're
///    wire-layer concerns outside the simulator). Both throw.
///  - Raw push-payload `processMessage(bytes:)` has no wire concept —
///    DTU doesn't carry an over-the-wire format, only in-memory values.
///    Throws.
///
/// The send flows (`prepare`, `sendOptimistic`, `publish`) map 1:1 onto
/// DTU's `prepare_message`, `send`, and `publish_messages` actions.
public final class DTUMessagingGroup: MessagingGroup, @unchecked Sendable {
    let context: DTUMessagingClientContext
    public let id: String

    /// DTU's `create_group` / sync actions don't surface creation
    /// timestamps in nanoseconds the way libxmtp does. We cache a
    /// locally-assigned value at construction time so `createdAtNs` /
    /// `lastActivityAtNs` are stable within a test run.
    private let assignedCreatedAtNs: Int64
    private let assignedLastActivityAtNs: Int64

    public init(
        context: DTUMessagingClientContext,
        conversationAlias: String,
        createdAtNs: Int64 = 0,
        lastActivityAtNs: Int64 = 0
    ) {
        self.context = context
        self.id = conversationAlias
        self.assignedCreatedAtNs = createdAtNs
        self.assignedLastActivityAtNs = lastActivityAtNs
    }

    // MARK: - MessagingConversationCore

    /// DTU doesn't surface a `topic` distinct from `id`. Return the
    /// conversation alias so consumers that key off `topic` still get a
    /// stable, unique value.
    public var topic: String { id }
    public var createdAtNs: Int64 { assignedCreatedAtNs }
    public var lastActivityAtNs: Int64 { assignedLastActivityAtNs }

    public func consentState() async throws -> MessagingConsentState {
        let state = try await context.universe.getConsentState(
            conversation: id,
            actor: context.actor
        )
        return MessagingConsentState(state)
    }

    public func updateConsentState(_ state: MessagingConsentState) async throws {
        _ = try await context.universe.updateConsentState(
            conversation: id,
            state: state.dtuConsentState,
            actor: context.actor
        )
    }

    public func debugInformation() async throws -> MessagingConversationDebugInfo {
        // DTU engine does not yet surface MLS epoch / commit-log state.
        // Return a zero-value snapshot marked `.unknown`; the audit's
        // expected behavior is that a DTU-backed caller never asserts
        // against debug info for production invariants.
        MessagingConversationDebugInfo(
            epoch: 0,
            maybeForked: false,
            forkDetails: "",
            localCommitLog: "",
            remoteCommitLog: "",
            commitLogForkStatus: .unknown
        )
    }

    public func sync() async throws {
        _ = try await context.universe.sync(actor: context.actor)
    }

    public func members() async throws -> [MessagingMember] {
        let result = try await context.universe.listMembers(
            conversation: id,
            actor: context.actor
        )
        // DTU's `list_members` surfaces just sorted inbox aliases — no
        // role / consent / identity per member. Fill with conservative
        // defaults: `.member` role, `.unknown` consent, no wallet
        // identities. Tests asserting richer member state must use the
        // XMTPiOS adapter.
        return result.members.map { alias in
            MessagingMember(
                inboxId: alias,
                identities: [],
                role: .member,
                consentState: .unknown
            )
        }
    }

    public func messages(query: MessagingMessageQuery) async throws -> [MessagingMessage] {
        let raw = try await context.universe.listMessages(
            conversation: id,
            actor: context.actor
        )
        let mapped = raw.map { MessagingMessage($0, conversationId: id) }
        return DTUMessageQueryApplier.apply(query, to: mapped)
    }

    public func lastMessage() async throws -> MessagingMessage? {
        let raw = try await context.universe.listMessages(
            conversation: id,
            actor: context.actor
        )
        // DTU returns messages sorted by sequence ascending; the last
        // entry is the newest. Filter out system / membership_change
        // messages — callers expect `lastMessage` to surface user
        // content, mirroring libxmtp's `last_message`.
        let newestApplication = raw.reversed().first { $0.kind == .application }
        guard let newestApplication else { return nil }
        return MessagingMessage(newestApplication, conversationId: id)
    }

    public func countMessages(query: MessagingMessageQuery) async throws -> Int64 {
        let filtered = try await messages(query: query)
        return Int64(filtered.count)
    }

    public func streamMessages(
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage> {
        // DTU's `open_message_stream` / `close_message_stream` actions
        // are open/close pairs that return the observed messages in a
        // batch on close — there's no incremental push channel. The
        // abstraction's `streamMessages` contract is a live stream, so
        // there's no faithful mapping. Return an empty immediately-
        // terminating stream; callers that need real-time semantics
        // should fall back to polling `messages(...)`.
        //
        // FIXME(stage5+): when DTU grows a real server-sent-events /
        // websocket channel, wire it through here.
        return AsyncThrowingStream { continuation in
            continuation.finish()
            onClose?()
        }
    }

    public func getHmacKeys() async throws -> MessagingHmacKeys {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.getHmacKeys",
            reason: "DTU engine does not model wire-format HMAC keys"
        )
    }

    public func getPushTopics() async throws -> [String] {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.getPushTopics",
            reason: "DTU engine does not model wire-format push topics"
        )
    }

    public func processMessage(bytes: Data) async throws -> MessagingMessage? {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.processMessage",
            reason: "DTU engine has no over-the-wire payload format to decrypt"
        )
    }

    // MARK: - Send flows

    public func prepare(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        let text = try DTUEncodedContentUnpacker.asText(encodedContent)
        let result = try await context.universe.prepareMessage(
            conversation: id,
            content: .text(text),
            actor: context.actor
        )
        return MessagingPreparedMessage(
            messageId: result.message,
            conversationId: id,
            deliveryStatus: .unpublished
        )
    }

    public func sendOptimistic(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        let text = try DTUEncodedContentUnpacker.asText(encodedContent)
        let result = try await context.universe.send(
            conversation: id,
            text: text,
            optimistic: true,
            actor: context.actor
        )
        return MessagingPreparedMessage(
            messageId: result.message,
            conversationId: id,
            deliveryStatus: .unpublished
        )
    }

    public func publish() async throws {
        _ = try await context.universe.publishMessages(
            conversation: id,
            actor: context.actor
        )
    }

    public func publish(messageId: String) async throws {
        _ = try await context.universe.publishMessage(
            messageId: messageId,
            actor: context.actor
        )
    }

    // MARK: - MessagingGroup specifics

    public func name() async throws -> String {
        // DTU engine does not store group metadata (name / image / desc)
        // in v0.1. Return empty string so conformers can read without
        // throwing; updaters below do throw.
        return ""
    }

    public func imageUrl() async throws -> String { "" }
    public func description() async throws -> String { "" }
    public func appData() async throws -> String { "" }

    public func updateAppData(_ appData: String) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.updateAppData",
            reason: "DTU engine does not yet model the appData metadata slot"
        )
    }

    public func updateName(_ name: String) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.updateName",
            reason: "DTU engine does not yet model group name metadata"
        )
    }

    public func updateImageUrl(_ url: String) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.updateImageUrl",
            reason: "DTU engine does not yet model group image metadata"
        )
    }

    public func updateDescription(_ description: String) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.updateDescription",
            reason: "DTU engine does not yet model group description metadata"
        )
    }

    public func addMembers(inboxIds: [MessagingInboxID]) async throws {
        _ = try await context.universe.addMembers(
            conversation: id,
            members: inboxIds,
            actor: context.actor
        )
    }

    public func removeMembers(inboxIds: [MessagingInboxID]) async throws {
        _ = try await context.universe.removeMembers(
            conversation: id,
            members: inboxIds,
            actor: context.actor
        )
    }

    public func permissionPolicySet() async throws -> MessagingPermissionPolicySet {
        let policy = try await context.universe.getGroupPermissionPolicy(
            conversation: id,
            actor: context.actor
        )
        return MessagingPermissionPolicySet(policy)
    }

    public func updateAddMemberPermission(_ permission: MessagingPermission) async throws {
        guard let dtuPolicy = permission.dtuPermissionPolicy else {
            throw DTUMessagingNotSupportedError(
                method: "MessagingGroup.updateAddMemberPermission",
                reason: "Cannot translate MessagingPermission.\(permission.rawValue) to DTU"
            )
        }
        _ = try await context.universe.updatePermissionPolicy(
            conversation: id,
            permissionType: .addMember,
            policy: dtuPolicy,
            metadataField: nil,
            actor: context.actor
        )
    }

    public func creatorInboxId() async throws -> MessagingInboxID {
        // Not exposed by DTU's engine — there is no `creator` field on
        // the list_members / list_conversations outputs. The abstraction
        // requires a value, so throw a scoped not-supported error.
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.creatorInboxId",
            reason: "DTU engine does not surface a group creator field"
        )
    }

    public func isCreator() async throws -> Bool {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.isCreator",
            reason: "DTU engine does not surface a group creator field"
        )
    }

    public func isAdmin(inboxId: MessagingInboxID) async throws -> Bool {
        let admins = try await listAdmins()
        return admins.contains(inboxId)
    }

    public func isSuperAdmin(inboxId: MessagingInboxID) async throws -> Bool {
        let superAdmins = try await listSuperAdmins()
        return superAdmins.contains(inboxId)
    }

    public func listAdmins() async throws -> [MessagingInboxID] {
        try await context.universe.listAdmins(
            conversation: id,
            actor: context.actor
        )
    }

    public func listSuperAdmins() async throws -> [MessagingInboxID] {
        try await context.universe.listSuperAdmins(
            conversation: id,
            actor: context.actor
        )
    }

    public func isActive() async throws -> Bool {
        // DTU's conversation-list entries carry an `isActive` flag per
        // actor; expose it here by fetching the list and looking up
        // this conversation. This is O(n) but n is small in the test
        // scenarios DTU targets.
        let entries = try await context.universe.listConversations(actor: context.actor)
        return entries.first { $0.alias == id }?.isActive ?? false
    }

    // MARK: - Admin management (Stage 3)

    /// Stage 3 migration: the DTU engine doesn't model admin /
    /// super-admin mutation yet. Throw a scoped not-supported error
    /// so callers that reach for these surfaces fail loudly on a
    /// DTU-backed client.
    public func addAdmin(inboxId: MessagingInboxID) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.addAdmin",
            reason: "DTU engine does not yet model admin mutation"
        )
    }

    public func removeAdmin(inboxId: MessagingInboxID) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.removeAdmin",
            reason: "DTU engine does not yet model admin mutation"
        )
    }

    public func addSuperAdmin(inboxId: MessagingInboxID) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.addSuperAdmin",
            reason: "DTU engine does not yet model super-admin mutation"
        )
    }

    public func removeSuperAdmin(inboxId: MessagingInboxID) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingGroup.removeSuperAdmin",
            reason: "DTU engine does not yet model super-admin mutation"
        )
    }
}

// MARK: - Permission projection helper

/// Reverse projection for the bits of `MessagingPermission` that have a
/// 1:1 DTU counterpart. `.unknown` has no mapping and returns nil; callers
/// at the adapter boundary throw on nil.
private extension MessagingPermission {
    var dtuPermissionPolicy: XMTPDTU.PermissionPolicy? {
        switch self {
        case .allow: return .allow
        case .deny: return .deny
        case .admin: return .admin
        case .superAdmin: return .superAdmin
        case .unknown: return nil
        }
    }
}

// MARK: - Query filter

/// Apply a `MessagingMessageQuery` to the pre-mapped message list returned
/// from DTU. DTU's `list_messages` action returns every message in
/// sequence order with no query parameters — the abstraction's limit /
/// beforeNs / afterNs / direction / delivery-status filters have to be
/// applied client-side.
enum DTUMessageQueryApplier {
    static func apply(
        _ query: MessagingMessageQuery,
        to messages: [MessagingMessage]
    ) -> [MessagingMessage] {
        var filtered = messages

        if let before = query.beforeNs {
            filtered = filtered.filter { $0.sentAtNs < before }
        }
        if let after = query.afterNs {
            filtered = filtered.filter { $0.sentAtNs > after }
        }
        switch query.deliveryStatus {
        case .all:
            break
        case .unpublished:
            filtered = filtered.filter { $0.deliveryStatus == .unpublished }
        case .published:
            filtered = filtered.filter { $0.deliveryStatus == .published }
        case .failed:
            filtered = filtered.filter { $0.deliveryStatus == .failed }
        }
        if let exclude = query.excludeSenderInboxIds, !exclude.isEmpty {
            let excludeSet = Set(exclude)
            filtered = filtered.filter { !excludeSet.contains($0.senderInboxId) }
        }
        if let excludeTypes = query.excludeContentTypes, !excludeTypes.isEmpty {
            let excludeSet = Set(excludeTypes)
            filtered = filtered.filter { !excludeSet.contains($0.encodedContent.type) }
        }
        switch query.direction {
        case .ascending:
            filtered.sort { $0.sentAtNs < $1.sentAtNs }
        case .descending:
            filtered.sort { $0.sentAtNs > $1.sentAtNs }
        }
        if let limit = query.limit, filtered.count > limit {
            filtered = Array(filtered.prefix(limit))
        }
        return filtered
    }
}
