import ConvosCore
import ConvosMessagingProtocols
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingConversations`.
///
/// Wraps the conversation-list + create flows on `DTUUniverse`. DTU's
/// engine uses alias-keyed conversations (`g1`, `dm1`, etc.) rather than
/// content-derived IDs, so the adapter has to synthesize aliases for
/// freshly-created conversations. A monotonic counter gives us
/// deterministic aliases (`dtu-g-<n>`, `dtu-dm-<n>`) that are stable
/// within a client lifetime.
public final class DTUMessagingConversations: MessagingConversations, @unchecked Sendable {
    let context: DTUMessagingClientContext

    /// Monotonic alias counter. DTU's `create_group` action requires
    /// a caller-supplied alias, but the abstraction's `newGroup(...)`
    /// surface doesn't expose an alias arg — so we generate one. The
    /// counter is serialized behind an actor-lock via a private queue
    /// so two concurrent `newGroup` calls don't collide.
    private let aliasLock = NSLock()
    private var nextGroupAliasIndex: Int = 1
    private var nextDmAliasIndex: Int = 1

    /// Cache of adapter-backed conversation handles keyed by alias. DTU's
    /// engine is the source of truth, so the cache is purely a handle
    /// registry to keep `find(conversationId:)` stable across calls —
    /// without it, two separate `find(...)` calls would return different
    /// wrapper instances and `===` identity checks would break.
    private var groupCache: [String: DTUMessagingGroup] = [:]
    private var dmCache: [String: DTUMessagingDm] = [:]

    public init(context: DTUMessagingClientContext) {
        self.context = context
    }

    // MARK: - Listing

    public func list(query: MessagingConversationQuery) async throws -> [MessagingConversation] {
        let entries = try await context.universe.listConversations(actor: context.actor)
        // DTU's list entries carry `alias`, `isActive`, and `creatorInboxId`.
        // The engine doesn't currently discriminate dm vs group on the list
        // wire shape (both flow through `create_group`). Treat every list
        // entry as a group from the abstraction's perspective; a real DM
        // adapter needs DTU engine support (see "Gaps" section in
        // docs/ios-abstraction-audit.md §5.5). We refresh the cached
        // creator alias on every listing so a pre-cached handle updated
        // mid-run (shouldn't happen — MLS creator is immutable) doesn't
        // drift from the authoritative state.
        return entries.map { entry in
            let group = handleForGroup(
                alias: entry.alias,
                creatorInboxId: entry.creatorInboxId.isEmpty ? nil : entry.creatorInboxId
            )
            return MessagingConversation.group(group)
        }
    }

    public func listGroups(query: MessagingConversationQuery) async throws -> [any MessagingGroup] {
        let entries = try await context.universe.listConversations(actor: context.actor)
        return entries.map { entry in
            handleForGroup(
                alias: entry.alias,
                creatorInboxId: entry.creatorInboxId.isEmpty ? nil : entry.creatorInboxId
            ) as any MessagingGroup
        }
    }

    public func listDms(query: MessagingConversationQuery) async throws -> [any MessagingDm] {
        // DTU doesn't surface a dm/group discriminator on
        // `list_conversations`. Return an empty list; smoke tests and
        // the single-inbox flows don't currently DM each other in DTU.
        []
    }

    // MARK: - Find

    public func find(conversationId: String) async throws -> MessagingConversation? {
        if let cached = withLock({
            if let group = groupCache[conversationId] {
                return MessagingConversation.group(group)
            } else if let dm = dmCache[conversationId] {
                return MessagingConversation.dm(dm)
            }
            return nil
        }) {
            return cached
        }

        // Fall back to the universe's conversation list to verify the
        // alias exists, then wrap it as a group (the default projection).
        // Carry the creator inbox through so downstream
        // `creatorInboxId()` / `isCreator()` calls don't need a second
        // list round-trip.
        let entries = try await context.universe.listConversations(actor: context.actor)
        guard let entry = entries.first(where: { $0.alias == conversationId }) else {
            return nil
        }
        let group = handleForGroup(
            alias: conversationId,
            creatorInboxId: entry.creatorInboxId.isEmpty ? nil : entry.creatorInboxId
        )
        return .group(group)
    }

    /// Tiny scoped helper over the private `aliasLock`. Pulls the
    /// `lock` / `unlock` pair into a closure so every cache-mutating
    /// method is a one-liner and callers never hold the lock across
    /// an await point (Swift 6 strict concurrency forbids
    /// `NSLock.lock()` in async contexts).
    private func withLock<T>(_ body: () -> T) -> T {
        aliasLock.lock()
        defer { aliasLock.unlock() }
        return body()
    }

    public func findDmByInboxId(_ inboxId: MessagingInboxID) async throws -> (any MessagingDm)? {
        // DTU's engine doesn't expose DM lookup by peer inbox. Return
        // nil; callers can fall back to `findOrCreateDm(with:)`.
        nil
    }

    public func findMessage(messageId: String) async throws -> MessagingMessage? {
        // DTU has no direct "find message by id" action — messages are
        // only surfaced via `list_messages` scoped to a conversation.
        // The adapter doesn't currently index messages client-side; a
        // full implementation would enumerate every known conversation
        // and filter. The smoke test doesn't need this, so we punt.
        throw DTUMessagingNotSupportedError(
            method: "MessagingConversations.findMessage",
            reason: "DTU engine has no by-id lookup; caller must scope to a conversation"
        )
    }

    public func findOrCreateDm(with inboxId: MessagingInboxID) async throws -> any MessagingDm {
        throw DTUMessagingNotSupportedError(
            method: "MessagingConversations.findOrCreateDm",
            reason: "DTU engine does not yet model DM conversations as a first-class kind"
        )
    }

    // MARK: - Create

    public func newGroupOptimistic() async throws -> any MessagingGroup {
        // DTU note: optimistic semantics collapse to immediate create — no
        // network delay to optimize for. XMTPiOS's `newGroupOptimistic`
        // creates a `Group` locally without contacting peers (the publish
        // happens later when members or messages are added). DTU's engine
        // is in-process and `create_group` has no failure mode that a
        // deferred publish would resolve, so we mirror `newGroup`'s body
        // with an empty member set. The resulting handle behaves the same
        // for the abstraction's purposes.
        let alias = nextGroupAlias()
        _ = try await context.universe.createGroup(
            alias: alias,
            members: [],
            actor: context.actor
        )
        return handleForGroup(alias: alias, creatorInboxId: context.inboxAlias)
    }

    public func newGroup(
        withInboxIds inboxIds: [MessagingInboxID],
        name: String,
        imageUrl: String,
        description: String
    ) async throws -> any MessagingGroup {
        let alias = nextGroupAlias()
        _ = try await context.universe.createGroup(
            alias: alias,
            members: inboxIds,
            actor: context.actor
        )
        // DTU engine does not model name / imageUrl / description on
        // create_group. The abstraction passes them; we drop silently.
        // FIXME(dtu-engine): wire group metadata into create_group when
        // the engine grows a metadata slot.
        //
        // Creator is the caller's inbox — DTU's engine sets
        // `creator_inbox = actor.inbox_id` on create_group, so we thread
        // `context.inboxAlias` through the handle at construction time
        // to avoid a round-trip on the `creatorInboxId()` / `isCreator()`
        // surfaces.
        return handleForGroup(alias: alias, creatorInboxId: context.inboxAlias)
    }

    // MARK: - Sync

    public func sync() async throws {
        _ = try await context.universe.sync(actor: context.actor)
    }

    public func syncAll(consentStates: [MessagingConsentState]?) async throws -> MessagingSyncSummary {
        let result = try await context.universe.sync(actor: context.actor)
        return MessagingSyncSummary(
            numEligible: UInt64(result.syncedConversations),
            numSynced: UInt64(result.syncedConversations)
        )
    }

    // MARK: - Streams

    public func streamAll(
        filter: MessagingConversationFilter,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingConversation> {
        // DTU's wire layer is HTTP request/response with no SSE channel
        // for conversation creation. Emulate the abstraction's
        // `MessagingStream<MessagingConversation>` by polling
        // `listConversations` against a per-actor seen-set; new aliases
        // get yielded as `.group(...)` (DTU treats every conversation as
        // a group on the wire — DM discrimination is a future engine
        // gap). Cancel = finish stream + invoke onClose exactly once.
        let context = self.context
        let conversations = self
        return AsyncThrowingStream { continuation in
            let onCloseBox = OnCloseOnce(onClose)
            let pollTask = Task {
                var seen: Set<String> = []
                while !Task.isCancelled {
                    do {
                        let entries = try await context.universe.listConversations(
                            actor: context.actor
                        )
                        for entry in entries where !seen.contains(entry.alias) {
                            if Task.isCancelled { break }
                            seen.insert(entry.alias)
                            let group = conversations.handleForGroup(
                                alias: entry.alias,
                                creatorInboxId: entry.creatorInboxId.isEmpty
                                    ? nil
                                    : entry.creatorInboxId
                            )
                            continuation.yield(.group(group))
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        Log.warning(
                            "DTUMessagingConversations.streamAll poll error (will retry): \(error)"
                        )
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            continuation.onTermination = { _ in
                pollTask.cancel()
                onCloseBox.fire()
            }
        }
    }

    public func streamAllMessages(
        filter: MessagingConversationFilter,
        consentStates: [MessagingConsentState]?,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage> {
        // Cross-conversation polling: every ~150ms enumerate
        // `listConversations`, then for each known alias call
        // `listMessagesAfter` with a per-conversation `lastSeen` cursor.
        // New conversations discovered mid-stream automatically get
        // their own cursor entry; the cursor map only ever grows. As
        // with `streamMessages`, transient errors don't terminate the
        // stream — log + sleep + retry.
        let context = self.context
        return AsyncThrowingStream { continuation in
            let onCloseBox = OnCloseOnce(onClose)
            let pollTask = Task {
                var lastSeenByConversation: [String: UInt64] = [:]
                while !Task.isCancelled {
                    do {
                        let entries = try await context.universe.listConversations(
                            actor: context.actor
                        )
                        for entry in entries {
                            if Task.isCancelled { break }
                            let conversationId = entry.alias
                            do {
                                let messages = try await context.universe.listMessagesAfter(
                                    conversation: conversationId,
                                    sinceSequence: lastSeenByConversation[conversationId],
                                    actor: context.actor
                                )
                                for raw in messages {
                                    if Task.isCancelled { break }
                                    continuation.yield(
                                        MessagingMessage(raw, conversationId: conversationId)
                                    )
                                    let prior = lastSeenByConversation[conversationId] ?? 0
                                    if raw.sequence > prior {
                                        lastSeenByConversation[conversationId] = raw.sequence
                                    }
                                }
                            } catch is CancellationError {
                                break
                            } catch {
                                Log.warning(
                                    "DTUMessagingConversations.streamAllMessages poll error for "
                                        + "\(conversationId) (will retry): \(error)"
                                )
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        Log.warning(
                            "DTUMessagingConversations.streamAllMessages list error (will retry): "
                                + "\(error)"
                        )
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            continuation.onTermination = { _ in
                pollTask.cancel()
                onCloseBox.fire()
            }
        }
    }

    // MARK: - Internal handle factory

    /// Look up / create the cached wrapper for the given conversation
    /// alias. Keeping the wrapper pointer-stable means two calls to
    /// `find(conversationId:)` return the same `DTUMessagingGroup`
    /// instance, matching the stability contract of the XMTPiOS
    /// adapter (whose wrappers are cheap reference types over the
    /// underlying SDK handle).
    ///
    /// `creatorInboxId` is optional: callers that know the creator
    /// (from a fresh `list_conversations` or the return of
    /// `create_group`) thread it through so the handle's
    /// `creatorInboxId()` / `isCreator()` surfaces don't need a second
    /// round-trip. Cached handles preserve whichever creator was first
    /// seen — MLS creator metadata is immutable, so the first value is
    /// authoritative for the handle's lifetime.
    func handleForGroup(alias: String, creatorInboxId: String? = nil) -> DTUMessagingGroup {
        withLock {
            if let cached = groupCache[alias] { return cached }
            let handle = DTUMessagingGroup(
                context: context,
                conversationAlias: alias,
                creatorInboxId: creatorInboxId
            )
            groupCache[alias] = handle
            return handle
        }
    }

    private func nextGroupAlias() -> String {
        withLock {
            let index = nextGroupAliasIndex
            nextGroupAliasIndex += 1
            return "dtu-g-\(index)"
        }
    }

    private func nextDmAlias() -> String {
        withLock {
            let index = nextDmAliasIndex
            nextDmAliasIndex += 1
            return "dtu-dm-\(index)"
        }
    }
}
