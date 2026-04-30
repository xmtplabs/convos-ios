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

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        deviceInfoProvider: (any DeviceInfoProviding)? = nil,
        conversationLister: any PushTopicConversationListing = XMTPPushTopicConversationLister()
    ) {
        self.identityStore = identityStore
        self.deviceRegistrationManager = deviceRegistrationManager
        self.deviceInfoProvider = deviceInfoProvider
        self.conversationLister = conversationLister
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
        await subscribe(
            to: conversationIds.map(inviteDMSubscription(conversationId:)),
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

    func reconcilePushTopics(
        params: SyncClientParams,
        context: String
    ) async {
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

        await subscribe(to: subscriptions, params: params, context: context)
    }

    // MARK: - Private

    private func subscribe(
        to subscriptions: [TopicSubscription],
        params: SyncClientParams,
        context: String
    ) async {
        let subscriptions = dedupe(subscriptions)
        guard !subscriptions.isEmpty else { return }
        guard let identity = await identity(matching: params) else { return }
        guard let deviceId = await deviceIdentifier(context: context) else { return }

        if let deviceRegistrationManager {
            await deviceRegistrationManager.registerDeviceIfNeeded()
        }

        do {
            try await params.apiClient.subscribeToTopics(
                deviceId: deviceId,
                clientId: identity.clientId,
                topics: subscriptions.map(\.topic)
            )
            Log.info("Subscribed to push topics \(context): \(topicSummary(subscriptions))")
            Log.debug("Subscribed push topic values \(context): \(subscriptions.map(\.topic).joined(separator: ", "))")
        } catch {
            Log.warning("Failed subscribing to push topics \(context): \(error)")
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
        }
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
