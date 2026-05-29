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

    // Reconcile pipeline (D8 hash debounce + D14 token-change trigger compatible):
    //
    //     reconcilePushTopics(params, context)
    //       |
    //       +-- computeReconcileDesiredSubscriptions  (welcome + groups + DMs)
    //       |
    //       +-- dedupe                                (per-topic uniqueness)
    //       |
    //       +-- if cache + token + identity available:
    //       |     |
    //       |     +-- cacheKey = (inboxId, clientId, deviceId, pushTokenSha256)
    //       |     +-- hash     = SHA256 of sorted-joined topic set
    //       |     +-- if cache.lookup(cacheKey) == hash -> SKIP (no wire call)
    //       |     +-- else                               -> subscribe(cacheKey)
    //       |
    //       +-- else (no cache wired, or no token/identity yet):
    //             +-- subscribe(cacheKey: nil)            (legacy "always send")
    //
    //     subscribe(to:params:context:cacheKey:)
    //       |
    //       +-- POST /v2/notifications/subscribe
    //       |     |
    //       |     +-- success -> log + if cacheKey != nil { cache.store(hash) }
    //       |     +-- throw   -> Log.warning + QAEvent + NO cache write
    //       |                    (next reconcile retries the wire)
    func reconcilePushTopics(
        params: SyncClientParams,
        context: String
    ) async {
        let subscriptions = await computeReconcileDesiredSubscriptions(
            params: params,
            context: context
        )
        let deduped = dedupe(subscriptions)
        guard !deduped.isEmpty else { return }

        guard let cache = cache,
              let cacheKey = await currentCacheKey(params: params, context: context) else {
            await subscribe(to: deduped, params: params, context: context, cacheKey: nil)
            return
        }
        let currentHash = PushTopicHash.of(deduped.map(\.topic))
        if let cached = cache.lookupHash(forKey: cacheKey.keyString), cached == currentHash {
            Log.debug("Reconcile no-op \(context): topic hash matches cached state")
            return
        }
        // Pass currentHash through so subscribe doesn't recompute SHA-256 over
        // the same topic set on success.
        await subscribe(
            to: deduped,
            params: params,
            context: context,
            cacheKey: cacheKey.keyString,
            precomputedHash: currentHash
        )
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
    private func computeReconcileDesiredSubscriptions(
        params: SyncClientParams,
        context: String
    ) async -> [TopicSubscription] {
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

        return subscriptions
    }

    // MARK: - Private

    private func subscribe(
        to subscriptions: [TopicSubscription],
        params: SyncClientParams,
        context: String,
        cacheKey: String? = nil,
        precomputedHash: String? = nil
    ) async {
        let subscriptions = dedupe(subscriptions)
        guard !subscriptions.isEmpty else { return }
        guard let identity = await identity(matching: params) else { return }
        guard let deviceId = await deviceIdentifier(context: context) else { return }

        if let deviceRegistrationManager {
            await deviceRegistrationManager.registerDeviceIfNeeded()
        }

        do {
            let response = try await params.apiClient.subscribeToTopics(
                deviceId: deviceId,
                clientId: identity.clientId,
                topics: subscriptions.map(\.topic),
                options: ConvosAPI.SubscribeOptions(
                    context: context,
                    source: "ios-main",
                    kindSummary: kindSummaryDict(subscriptions)
                )
            )
            Log.info(
                "Subscribed to push topics \(context): \(topicSummary(subscriptions)) "
                + "remoteApplied=\(response.remoteApplied) skipped=\(response.skipped ?? "nil")"
            )
            Log.debug("Subscribed push topic values \(context): \(subscriptions.map(\.topic).joined(separator: ", "))")
            // D16: cache writes ONLY when the backend actually applied the
            // subscribe at the XMTP notifications server. Skipping when
            // skipped == "idempotent" is fine — backend's snapshot tells
            // us the state is current. Skipping when skipped == "no_push_
            // token" / "disabled" leaves the cache stale on purpose so the
            // next reconcile attempts to send (covers the case where the
            // device gets a token / gets re-enabled and we haven't received
            // a token-change notification yet).
            if let cacheKey = cacheKey, let cache = cache, response.remoteApplied {
                let hash = precomputedHash ?? PushTopicHash.of(subscriptions.map(\.topic))
                cache.storeHash(hash, forKey: cacheKey)
            } else if let skipped = response.skipped {
                Log.info(
                    "Skipping cache write for \(context): backend returned skipped=\(skipped) "
                    + "(remoteApplied=\(response.remoteApplied)); next reconcile will retry"
                )
            }
        } catch {
            Log.warning("Failed subscribing to push topics \(context): \(error)")
            QAEvent.emit(.sync, "push_topic_subscribe_failed", [
                "context": context,
                "topic_count": String(subscriptions.count),
                "kinds": kindSummary(subscriptions),
                "error": String(describing: error),
            ])
        }
    }

    private func unsubscribe(
        topics: [String],
        params: SyncClientParams,
        context: String
    ) async {
        let topics = Array(Set(topics)).sorted()
        guard !topics.isEmpty else { return }
        guard let identity = await identity(matching: params) else { return }

        do {
            try await params.apiClient.unsubscribeFromTopics(
                clientId: identity.clientId,
                topics: topics
            )
            Log.info("Unsubscribed from push topics \(context): \(topics.joined(separator: ", "))")
        } catch {
            Log.warning("Failed unsubscribing from push topics \(context): \(error)")
            QAEvent.emit(.sync, "push_topic_unsubscribe_failed", [
                "context": context,
                "topic_count": String(topics.count),
                "error": String(describing: error),
            ])
        }
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

    private func topicSummary(_ subscriptions: [TopicSubscription]) -> String {
        subscriptions
            .map { "\($0.kind.rawValue):\($0.sourceId)" }
            .joined(separator: ", ")
    }

    private func kindSummary(_ subscriptions: [TopicSubscription]) -> String {
        kindSummaryDict(subscriptions)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    /// Structured kind counts for the subscribe request body (Stack 2 D6).
    /// Same data as `kindSummary(_:)` but typed as a dict for JSON encoding.
    private func kindSummaryDict(_ subscriptions: [TopicSubscription]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for subscription in subscriptions {
            counts[subscription.kind.rawValue, default: 0] += 1
        }
        return counts
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
