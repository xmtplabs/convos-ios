import Foundation
@preconcurrency import XMTPiOS

/// Owns the per-installation push-topic subscription state with the Convos backend.
///
/// Subscriptions are keyed by APNS topic string; each call resolves the
/// caller's keychain identity and device id, then issues a single
/// subscribe/unsubscribe to `apiClient`. Failures are logged but never
/// propagated — callers treat push subscriptions as best-effort so a
/// transient API failure does not block message processing or join flows.
protocol PushTopicSubscriptionManaging: Actor {
    /// Subscribes to the group's message topic and the inbox-wide welcome
    /// topic. Use after a group is created or joined.
    func subscribeToGroupAndWelcome(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async

    /// Subscribes to a DM that is hosting an invite join-request flow so
    /// the creator receives the joiner's signed slug as a push.
    func subscribeToInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async

    /// Unsubscribes from an invite DM. Used when a join request is rejected
    /// for malicious reasons so the spammer can no longer wake the device.
    func unsubscribeFromInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async

    /// Re-derives and resends the full topic set (welcome + groups +
    /// invite DMs) so server state matches the local conversation list.
    /// Called on resume / cold start to recover from missed deltas.
    func reconcilePushTopics(
        params: SyncClientParams,
        context: String
    ) async

    /// Drops every cached push-topic-set hash. Production callers invoke
    /// this on sign-out / "Delete all data" paths; tests use it to force
    /// a deterministic cache miss.
    func clearCache() async
}

protocol PushTopicConversationListing: Sendable {
    func listGroupConversationIds(
        params: SyncClientParams,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [String]

    func listInviteDMConversationIds(
        params: SyncClientParams,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [String]
}

struct XMTPPushTopicConversationLister: PushTopicConversationListing {
    func listGroupConversationIds(
        params: SyncClientParams,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [String] {
        try params.client.conversationsProvider.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: nil,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: consentStates,
            orderBy: orderBy
        )
        .map(\.id)
    }

    func listInviteDMConversationIds(
        params: SyncClientParams,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [String] {
        try params.client.conversationsProvider.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: consentStates,
            orderBy: orderBy
        )
        .map(\.id)
    }
}

actor PushTopicSubscriptionManager: PushTopicSubscriptionManaging {
    /// Backend `/v2/notifications/subscribe` and `/unsubscribe` reject any
    /// request carrying more than 100 topics — wholesale, so a 101-topic
    /// subscribe applies *nothing*. Every wire call therefore loops in chunks
    /// of at most this many topics. This is a per-request cap, not a per-device
    /// total cap: a user in 500 conversations is fine across 5 batches.
    private static let maxTopicsPerRequest: Int = 100

    private enum TopicKind: String, Sendable {
        case welcome
        case group
        case inviteDM
    }

    private struct TopicSubscription: Sendable {
        let kind: TopicKind
        let topic: String
        let sourceId: String
    }

    private let identityStore: any KeychainIdentityStoreProtocol
    private let deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)?
    private let deviceInfoProvider: (any DeviceInfoProviding)?
    private let conversationLister: any PushTopicConversationListing
    /// Hash debounce cache. When nil, every reconcile hits the wire (used by
    /// tests that want to assert delivery without thinking about caching, and
    /// by NSE one-shot constructions where reconcile is never called).
    private let cache: PushTopicSubscriptionCache?
    /// Returns the current APNS token, hashed into the cache key so token
    /// rotation forces a miss. Closure-based so tests can drive both nil and
    /// non-nil paths without touching the global singleton.
    private let pushTokenProvider: (@Sendable () -> String?)?

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        deviceInfoProvider: (any DeviceInfoProviding)? = nil,
        conversationLister: any PushTopicConversationListing = XMTPPushTopicConversationLister(),
        cache: PushTopicSubscriptionCache? = nil,
        pushTokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.identityStore = identityStore
        self.deviceRegistrationManager = deviceRegistrationManager
        self.deviceInfoProvider = deviceInfoProvider
        self.conversationLister = conversationLister
        self.cache = cache
        self.pushTokenProvider = pushTokenProvider
    }

    func subscribeToGroupAndWelcome(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        await subscribeToGroupsAndWelcome(
            conversationIds: [conversationId],
            params: params,
            context: context
        )
    }

    func subscribeToGroupsAndWelcome(
        conversationIds: [String],
        params: SyncClientParams,
        context: String
    ) async {
        guard !conversationIds.isEmpty else { return }
        var subscriptions: [TopicSubscription] = conversationIds.map(groupSubscription(conversationId:))
        subscriptions.append(welcomeSubscription(params: params))
        await subscribe(to: subscriptions, params: params, context: context)
    }

    func subscribeToInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        await subscribeToInviteDMTopics(
            conversationIds: [conversationId],
            params: params,
            context: context
        )
    }

    func subscribeToInviteDMTopics(
        conversationIds: [String],
        params: SyncClientParams,
        context: String
    ) async {
        guard !conversationIds.isEmpty else { return }
        let allowed = await filterAllowedInviteDMs(
            conversationIds: conversationIds,
            params: params,
            context: context
        )
        guard !allowed.isEmpty else { return }
        await subscribe(
            to: allowed.map(inviteDMSubscription(conversationId:)),
            params: params,
            context: context
        )
    }

    func unsubscribeFromInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        await unsubscribeFromInviteDMTopics(
            conversationIds: [conversationId],
            params: params,
            context: context
        )
    }

    func unsubscribeFromInviteDMTopics(
        conversationIds: [String],
        params: SyncClientParams,
        context: String
    ) async {
        guard !conversationIds.isEmpty else { return }
        await unsubscribe(
            topics: conversationIds.map(\.xmtpGroupTopicFormat),
            params: params,
            context: context
        )
    }

    // Reconcile pipeline (delta-based, applied-topic mirror, ≤100-topic batches):
    //
    //     reconcilePushTopics(params, context)
    //       |
    //       +-- computeReconcileDesiredSubscriptions  (welcome + groups + DMs)
    //       +-- dedupe                                (per-topic uniqueness)
    //       |
    //       +-- if cache + token + identity available:
    //       |     |
    //       |     +-- cacheKey = (inboxId, clientId, deviceId, pushTokenSha256)
    //       |     +-- applied  = cache.lookupTopics(cacheKey)   (nil = cold start)
    //       |     +-- if applied == desired -> SKIP (no wire call)
    //       |     +-- else:
    //       |          +-- toAdd    = desired − applied (full desired if nil)
    //       |          +-- toRemove = applied − desired
    //       |          +-- subscribe(toAdd)   in ≤100 chunks   (additive)
    //       |          +-- unsubscribe(toRemove) in ≤100 chunks (delta removal)
    //       |          +-- if ALL batches succeeded -> cache.storeTopics(desired)
    //       |          +-- else                     -> leave mirror stale
    //       |                                          (next reconcile re-converges;
    //       |                                           additive subscribe is
    //       |                                           idempotent so retry is safe)
    //       |
    //       +-- else (no cache wired, or no token/identity yet):
    //             +-- subscribe(full desired) in ≤100 chunks (legacy "always send")
    //
    // HARD RULE: the failure path NEVER calls deleteInstallation/unregister.
    // A stale mirror plus additive+idempotent re-subscribe is the entire
    // recovery mechanism; there is no destructive reset anywhere in here.
    func reconcilePushTopics(
        params: SyncClientParams,
        context: String
    ) async {
        let desired = await computeReconcileDesiredSubscriptions(
            params: params,
            context: context
        )
        let deduped = dedupe(desired.subscriptions)
        guard !deduped.isEmpty else { return }
        let desiredTopics = deduped.map(\.topic)

        guard let cache = cache,
              let cacheKey = await currentCacheKey(params: params, context: context) else {
            // No cache wired (tests) or no token/identity yet: fall back to a
            // full chunked additive subscribe every time. No mirror to persist.
            _ = await sendSubscribe(topics: desiredTopics, params: params, context: context)
            return
        }

        let key = cacheKey.keyString
        let applied = cache.lookupTopics(forKey: key)
        let desiredSet = Set(desiredTopics)

        // Mirror already matches desired -> nothing to converge. Only short-
        // circuit on a non-degraded pass: a degraded desired set that happens
        // to equal a (previously shrunk) mirror must NOT be treated as settled.
        if !desired.isDegraded, let applied = applied, Set(applied) == desiredSet {
            Log.debug("Reconcile no-op \(context): applied topic mirror matches desired state")
            return
        }

        // Cold start / nil mirror -> toAdd is the full desired set (additive
        // re-subscribe repairs any missed subscriptions).
        let appliedSet = Set(applied ?? [])
        let toAdd = desiredTopics.filter { !appliedSet.contains($0) }

        // CRITICAL: only compute removals from an AUTHORITATIVE (non-degraded)
        // desired set. When a conversation listing failed, the desired set is
        // incomplete, so `applied - desired` would wrongly flag every topic of
        // the failed source for unsubscribe. In that case we do the additive
        // subscribe only, skip removals, and leave the mirror stale so the next
        // (hopefully complete) reconcile re-converges. This is the additive,
        // non-destructive recovery the design relies on — never deleteInstallation.
        let toRemove: [String] = desired.isDegraded
            ? []
            : (applied ?? []).filter { !desiredSet.contains($0) }

        var allSucceeded = true
        if !toAdd.isEmpty {
            let added = await sendSubscribe(topics: toAdd, params: params, context: context)
            allSucceeded = allSucceeded && added
        }
        if !toRemove.isEmpty {
            let removed = await sendUnsubscribe(topics: toRemove, params: params, context: context)
            allSucceeded = allSucceeded && removed
        }

        // Persist the mirror = desired ONLY when every batch landed AND the
        // desired set was authoritative. A degraded pass never persists (its
        // desired set is incomplete); a partial wire failure never persists
        // (so the next trigger recomputes the same delta and retries). Subscribe
        // is additive + idempotent, so re-sending already-applied topics is
        // harmless.
        if allSucceeded, !desired.isDegraded {
            cache.storeTopics(desiredTopics, forKey: key)
        } else if !allSucceeded {
            Log.warning("Reconcile partial failure \(context): leaving applied mirror stale for retry")
        } else {
            Log.warning("Reconcile degraded \(context): incomplete desired set, leaving mirror stale")
        }
    }

    /// Clears the hash debounce cache. Call on "Delete all data" / sign-out
    /// paths when the caller wants to drop every previously-recorded state,
    /// not just rely on partitioning by identity. Day-to-day identity rotation
    /// is already handled by the cache key including `inboxId` and `clientId`
    /// (a new identity reads through a fresh key automatically).
    func clearCache() {
        cache?.clearAll()
    }

    private func currentCacheKey(
        params: SyncClientParams,
        context: String
    ) async -> PushTopicCacheKey? {
        guard let identity = await identity(matching: params) else { return nil }
        guard let deviceId = await deviceIdentifier(context: context) else { return nil }
        let token = pushTokenProvider?()
        return PushTopicCacheKey(
            inboxId: identity.inboxId,
            clientId: identity.clientId,
            deviceId: deviceId,
            pushTokenSha256: PushTopicHash.ofToken(token)
        )
    }

    /// Computes the full desired topic set for a reconcile pass without sending
    /// anything to the backend. Pulling this out of `reconcilePushTopics` lets
    /// the debounce path (D8) compute a hash and decide whether to send, and
    /// gives Stack 2's diagnostics surface the same source-of-truth iOS uses
    /// to derive desired state. The per-conversation `subscribeToGroup...` /
    /// `subscribeToInviteDMTopics` paths keep their own narrow builders since
    /// they're firing one-shot deltas, not a full sweep.
    /// Result of computing the desired topic set for a reconcile. `isDegraded`
    /// is `true` when one of the conversation listings threw, meaning the
    /// `subscriptions` set is INCOMPLETE — it is missing the topics for the
    /// source that failed. The delta reconcile must never treat a degraded
    /// (incomplete) desired set as authoritative for removals, or a transient
    /// listing failure would unsubscribe every previously-applied topic for
    /// that source.
    private struct DesiredSubscriptions {
        let subscriptions: [TopicSubscription]
        let isDegraded: Bool
    }

    private func computeReconcileDesiredSubscriptions(
        params: SyncClientParams,
        context: String
    ) async -> DesiredSubscriptions {
        var subscriptions: [TopicSubscription] = [welcomeSubscription(params: params)]
        var degradedSources: [String] = []

        do {
            let groupIds = try conversationLister.listGroupConversationIds(
                params: params,
                consentStates: params.consentStates,
                orderBy: .lastActivity
            )
            subscriptions.append(contentsOf: groupIds.map(groupSubscription(conversationId:)))
        } catch {
            Log.warning("Failed listing groups for push topic reconciliation \(context): \(error)")
            degradedSources.append("groups")
        }

        do {
            let dmIds = try conversationLister.listInviteDMConversationIds(
                params: params,
                consentStates: [.unknown, .allowed],
                orderBy: .lastActivity
            )
            subscriptions.append(contentsOf: dmIds.map(inviteDMSubscription(conversationId:)))
        } catch {
            Log.warning("Failed listing DMs for push topic reconciliation \(context): \(error)")
            degradedSources.append("dms")
        }

        // Surface partial reconciles as a structured event so dashboards
        // can spot the case where the device is on a stale topic set
        // (only welcome was re-subscribed). The happy path stays silent.
        if !degradedSources.isEmpty {
            QAEvent.emit(.sync, "push_topic_reconcile_degraded", [
                "context": context,
                "missing": degradedSources.joined(separator: ","),
            ])
        }

        return DesiredSubscriptions(subscriptions: subscriptions, isDegraded: !degradedSources.isEmpty)
    }

    // MARK: - Private

    /// Per-conversation subscribe entry point (group join / invite DM). Sends
    /// the topics in ≤100 chunks and, on full success, folds them into the
    /// applied-topic mirror so it stays accurate between full reconciles.
    /// Returns nothing — callers treat push subscription as best-effort.
    private func subscribe(
        to subscriptions: [TopicSubscription],
        params: SyncClientParams,
        context: String
    ) async {
        let subscriptions = dedupe(subscriptions)
        guard !subscriptions.isEmpty else { return }
        let topics = subscriptions.map(\.topic)
        let succeeded = await sendSubscribe(
            topics: topics,
            params: params,
            context: context,
            kindSubscriptions: subscriptions
        )
        // Mirror update is best-effort and additive: only record topics that
        // actually landed. A failed batch leaves the mirror untouched so the
        // next full reconcile re-derives and re-applies the missing topic.
        if succeeded, let cache = cache,
           let cacheKey = await currentCacheKey(params: params, context: context) {
            cache.addTopics(topics, forKey: cacheKey.keyString)
        }
    }

    private func unsubscribe(
        topics: [String],
        params: SyncClientParams,
        context: String
    ) async {
        let topics = Array(Set(topics)).sorted()
        guard !topics.isEmpty else { return }
        let succeeded = await sendUnsubscribe(topics: topics, params: params, context: context)
        // Drop the topics from the mirror only after the wire call succeeded,
        // mirroring the additive subscribe path. A failed unsubscribe leaves
        // the mirror as-is; the next full reconcile recomputes toRemove.
        if succeeded, let cache = cache,
           let cacheKey = await currentCacheKey(params: params, context: context) {
            cache.removeTopics(topics, forKey: cacheKey.keyString)
        }
    }

    /// Low-level chunked subscribe. Resolves identity/device once, then issues
    /// one `subscribeToTopics` call per ≤100-topic chunk. Returns `true` only
    /// when every chunk succeeded; a single failed chunk returns `false` (and
    /// is logged per-chunk) so callers know not to persist the mirror.
    ///
    /// `kindSubscriptions` is an optional richer view of the same topics used
    /// only for human-readable logging/QA summaries on the per-conversation
    /// path; the reconcile path passes plain topic strings.
    private func sendSubscribe(
        topics: [String],
        params: SyncClientParams,
        context: String,
        kindSubscriptions: [TopicSubscription]? = nil
    ) async -> Bool {
        guard !topics.isEmpty else { return true }
        guard let identity = await identity(matching: params) else { return false }
        guard let deviceId = await deviceIdentifier(context: context) else { return false }

        if let deviceRegistrationManager {
            await deviceRegistrationManager.registerDeviceIfNeeded()
        }

        var allSucceeded = true
        for chunk in topics.chunked(into: Self.maxTopicsPerRequest) {
            do {
                try await params.apiClient.subscribeToTopics(
                    deviceId: deviceId,
                    clientId: identity.clientId,
                    topics: chunk
                )
                Log.info("Subscribed to push topics \(context): \(chunk.count) topic(s)")
                Log.debug("Subscribed push topic values \(context): \(chunk.joined(separator: ", "))")
            } catch {
                allSucceeded = false
                Log.warning("Failed subscribing to push topics \(context): \(error)")
                QAEvent.emit(.sync, "push_topic_subscribe_failed", [
                    "context": context,
                    "topic_count": String(chunk.count),
                    "kinds": kindSummary(kindSubscriptions, fallbackCount: chunk.count),
                    "error": String(describing: error),
                ])
            }
        }
        return allSucceeded
    }

    /// Low-level chunked unsubscribe. One `unsubscribeFromTopics` call per
    /// ≤100-topic chunk. Returns `true` only when every chunk succeeded.
    private func sendUnsubscribe(
        topics: [String],
        params: SyncClientParams,
        context: String
    ) async -> Bool {
        guard !topics.isEmpty else { return true }
        guard let identity = await identity(matching: params) else { return false }

        var allSucceeded = true
        for chunk in topics.chunked(into: Self.maxTopicsPerRequest) {
            do {
                try await params.apiClient.unsubscribeFromTopics(
                    clientId: identity.clientId,
                    topics: chunk
                )
                Log.info("Unsubscribed from push topics \(context): \(chunk.joined(separator: ", "))")
            } catch {
                allSucceeded = false
                Log.warning("Failed unsubscribing from push topics \(context): \(error)")
                QAEvent.emit(.sync, "push_topic_unsubscribe_failed", [
                    "context": context,
                    "topic_count": String(chunk.count),
                    "error": String(describing: error),
                ])
            }
        }
        return allSucceeded
    }

    /// Drops invite DMs whose current consent is `.denied`. The user has
    /// explicitly opted out of that DM, so re-subscribing on a benign
    /// processing failure (or any retry path) would re-arm pushes the
    /// user actively rejected. Conversations we can't resolve (mock
    /// clients, transient lookup failures) fall through unchanged so we
    /// preserve the previous best-effort behaviour for tests and
    /// degraded states.
    private func filterAllowedInviteDMs(
        conversationIds: [String],
        params: SyncClientParams,
        context: String
    ) async -> [String] {
        var allowed: [String] = []
        var dropped: [String] = []
        for id in conversationIds {
            let conversation: XMTPiOS.Conversation?
            do {
                conversation = try await params.client.conversationsProvider.findConversation(conversationId: id)
            } catch {
                Log.warning("Failed loading DM \(id) consent for push subscribe \(context): \(error)")
                allowed.append(id)
                continue
            }
            guard let conversation else {
                allowed.append(id)
                continue
            }
            let consent: ConsentState
            do {
                consent = try conversation.consentState()
            } catch {
                Log.warning("Failed reading DM \(id) consent for push subscribe \(context): \(error)")
                allowed.append(id)
                continue
            }
            if consent == .denied {
                dropped.append(id)
            } else {
                allowed.append(id)
            }
        }
        if !dropped.isEmpty {
            QAEvent.emit(.sync, "push_topic_subscribe_skipped_denied", [
                "context": context,
                "count": String(dropped.count),
            ])
            Log.info("Skipping push subscribe for denied DMs \(context): \(dropped.joined(separator: ", "))")
        }
        return allowed
    }

    private func identity(matching params: SyncClientParams) async -> KeychainIdentity? {
        let loaded: KeychainIdentity?
        do {
            loaded = try await identityStore.load()
        } catch {
            Log.warning("Failed loading identity, skipping push topic subscription: \(error)")
            return nil
        }
        guard let identity = loaded else {
            Log.warning("Identity not found in keychain, skipping push topic subscription")
            return nil
        }
        guard identity.inboxId == params.client.inboxId else {
            Log.warning(
                "Identity inbox mismatch, skipping push topic subscription "
                + "(stored=\(identity.inboxId), requested=\(params.client.inboxId))"
            )
            return nil
        }
        return identity
    }

    private func deviceIdentifier(context: String) async -> String? {
        if let deviceInfoProvider {
            return deviceInfoProvider.deviceIdentifier
        }
        guard deviceRegistrationManager != nil else {
            Log.warning("DeviceRegistrationManager not available, skipping push topic subscription \(context)")
            return nil
        }
        return DeviceInfo.deviceIdentifier
    }

    private func dedupe(_ subscriptions: [TopicSubscription]) -> [TopicSubscription] {
        // APNS subscription state is keyed by topic; source kind is only used for logging.
        var seen: Set<String> = []
        var result: [TopicSubscription] = []
        for subscription in subscriptions where seen.insert(subscription.topic).inserted {
            result.append(subscription)
        }
        return result
    }

    /// Builds the `kinds=...` QA breakdown for a failed subscribe chunk. The
    /// reconcile path sends plain topic strings (no kind metadata), so it falls
    /// back to a bare count; the per-conversation path passes the richer
    /// `TopicSubscription` list and gets a per-kind tally.
    private func kindSummary(_ subscriptions: [TopicSubscription]?, fallbackCount: Int) -> String {
        guard let subscriptions = subscriptions else {
            return "topics=\(fallbackCount)"
        }
        var counts: [String: Int] = [:]
        for subscription in subscriptions {
            counts[subscription.kind.rawValue, default: 0] += 1
        }
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    private func welcomeSubscription(params: SyncClientParams) -> TopicSubscription {
        TopicSubscription(
            kind: .welcome,
            topic: params.client.installationId.xmtpWelcomeTopicFormat,
            sourceId: params.client.installationId
        )
    }

    private func groupSubscription(conversationId: String) -> TopicSubscription {
        TopicSubscription(
            kind: .group,
            topic: conversationId.xmtpGroupTopicFormat,
            sourceId: conversationId
        )
    }

    private func inviteDMSubscription(conversationId: String) -> TopicSubscription {
        TopicSubscription(
            kind: .inviteDM,
            topic: conversationId.xmtpGroupTopicFormat,
            sourceId: conversationId
        )
    }
}

private extension Array {
    /// Splits the array into sub-arrays of at most `size` elements, preserving
    /// order. Used to keep every push subscribe/unsubscribe wire call within
    /// the backend's 100-topic-per-request limit.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
