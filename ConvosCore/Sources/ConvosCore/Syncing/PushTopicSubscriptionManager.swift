import Foundation
@preconcurrency import XMTPiOS

protocol PushTopicSubscriptionManaging: Actor {
    func subscribeToGroupAndWelcome(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async

    func subscribeToInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async

    func unsubscribeFromInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async

    func reconcilePushTopics(
        params: SyncClientParams,
        context: String
    ) async
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

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        deviceInfoProvider: (any DeviceInfoProviding)? = nil
    ) {
        self.identityStore = identityStore
        self.deviceRegistrationManager = deviceRegistrationManager
        self.deviceInfoProvider = deviceInfoProvider
    }

    func subscribeToGroupAndWelcome(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        await subscribe(
            to: [
                groupSubscription(conversationId: conversationId),
                welcomeSubscription(params: params)
            ],
            params: params,
            context: context
        )
    }

    func subscribeToInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        await subscribe(
            to: [inviteDMSubscription(conversationId: conversationId)],
            params: params,
            context: context
        )
    }

    func unsubscribeFromInviteDMTopic(
        conversationId: String,
        params: SyncClientParams,
        context: String
    ) async {
        await unsubscribe(
            topics: [conversationId.xmtpGroupTopicFormat],
            params: params,
            context: context
        )
    }

    func reconcilePushTopics(
        params: SyncClientParams,
        context: String
    ) async {
        var subscriptions: [TopicSubscription] = [welcomeSubscription(params: params)]

        do {
            let groups = try params.client.conversationsProvider.listGroups(
                createdAfterNs: nil,
                createdBeforeNs: nil,
                lastActivityAfterNs: nil,
                lastActivityBeforeNs: nil,
                limit: nil,
                consentStates: params.consentStates,
                orderBy: .lastActivity
            )
            subscriptions.append(contentsOf: groups.map { groupSubscription(conversationId: $0.id) })
        } catch {
            Log.warning("Failed listing groups for push topic reconciliation \(context): \(error)")
        }

        do {
            let dms = try params.client.conversationsProvider.listDms(
                createdAfterNs: nil,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: nil,
                consentStates: [.unknown, .allowed],
                orderBy: .lastActivity
            )
            subscriptions.append(contentsOf: dms.map { inviteDMSubscription(conversationId: $0.id) })
        } catch {
            Log.warning("Failed listing DMs for push topic reconciliation \(context): \(error)")
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
        do {
            guard let identity = try await identityStore.load(),
                  identity.inboxId == params.client.inboxId else {
                Log.warning("Identity not found, skipping push topic subscription for inbox \(params.client.inboxId)")
                return nil
            }
            return identity
        } catch {
            Log.warning("Failed loading identity, skipping push topic subscription: \(error)")
            return nil
        }
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
