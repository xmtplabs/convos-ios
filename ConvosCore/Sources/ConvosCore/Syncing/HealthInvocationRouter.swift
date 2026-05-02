import ConvosConnections
import Foundation

/// Routes health subscribe/unsubscribe invocations to the
/// `HealthBackgroundSubscriptionManager`, gates them on the read capability, and re-applies
/// observer registration after a successful registry mutation.
///
/// Lives next to `ConnectionInvocationRuntime` because it needs the conversationId and the
/// sender's inbox id, neither of which is available to a `DataSink`. Pulled out so the
/// routing rules can be exercised without a `DecodedMessage` or a real XMTP client.
actor HealthInvocationRouter {
    private let enablementStore: any EnablementStore
    private let manager: HealthBackgroundSubscriptionManager
    private let routine: HealthBackgroundObserverRoutine
    private let delivery: any ConnectionDelivering

    init(
        enablementStore: any EnablementStore,
        manager: HealthBackgroundSubscriptionManager,
        routine: HealthBackgroundObserverRoutine,
        delivery: any ConnectionDelivering
    ) {
        self.enablementStore = enablementStore
        self.manager = manager
        self.routine = routine
        self.delivery = delivery
    }

    /// True when `invocation` is a health subscribe or unsubscribe — the only two actions
    /// the runtime intercepts here. Everything else flows through the standard
    /// `ConnectionsManager` chain.
    static func intercepts(_ invocation: ConnectionInvocation) -> Bool {
        guard invocation.kind == .health else { return false }
        let name = invocation.action.name
        return name == HealthActionSchemas.subscribeBackgroundDelivery.actionName
            || name == HealthActionSchemas.unsubscribeBackgroundDelivery.actionName
    }

    @discardableResult
    func route(
        invocation: ConnectionInvocation,
        conversationId: String,
        agentInboxId: String
    ) async -> ConnectionInvocationResult {
        let actionName = invocation.action.name
        let isSubscribe = actionName == HealthActionSchemas.subscribeBackgroundDelivery.actionName

        let enabled = await enablementStore.isEnabled(
            kind: .health,
            capability: .read,
            conversationId: conversationId
        )
        guard enabled else {
            let result = ConnectionInvocationResult(
                invocationId: invocation.invocationId,
                kind: .health,
                actionName: actionName,
                status: .capabilityNotEnabled,
                errorMessage: "Capability \(ConnectionCapability.read.rawValue) is not enabled for this conversation."
            )
            try? await delivery.deliver(result, to: conversationId)
            return result
        }

        let result: ConnectionInvocationResult
        if isSubscribe {
            result = await manager.handleSubscribe(
                invocation: invocation,
                conversationId: conversationId,
                agentInboxId: agentInboxId
            )
        } else {
            result = await manager.handleUnsubscribe(
                invocation: invocation,
                conversationId: conversationId,
                agentInboxId: agentInboxId
            )
        }

        try? await delivery.deliver(result, to: conversationId)

        if result.status == .success,
           let typeIdentifier = Self.parsedTypeIdentifier(from: invocation) {
            do {
                try await routine.applyForType(typeIdentifier)
            } catch {
                Log.error("Failed to apply observer for \(typeIdentifier.rawValue): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func parsedTypeIdentifier(from invocation: ConnectionInvocation) -> HealthSampleType? {
        let raw = invocation.action.arguments["typeIdentifier"]?.enumRawValue
            ?? invocation.action.arguments["typeIdentifier"]?.stringValue
        guard let raw else { return nil }
        return HealthSampleType(rawValue: raw)
    }
}
