import ConvosConnections
import ConvosConnectionsXMTP
import Foundation
@preconcurrency import XMTPiOS

/// Per-inbox runtime that decodes incoming `ConnectionInvocation` messages and routes them
/// to the right handler.
///
/// Two paths:
/// 1. Health background subscribe/unsubscribe — intercepted via `HealthInvocationRouter`
///    because the manager needs `conversationId` and the sender's `inboxId`, neither of
///    which is available to a `DataSink`.
/// 2. Everything else — flows through the standard `ConnectionsManager` +
///    `XMTPInvocationListener` chain (sink lookup, capability gate, confirmation, dispatch).
///
/// Health observer routine and delivery are built lazily on the first `process()` call,
/// once an `XMTPClientProvider` is available. `routine.start()` is invoked at that time so
/// existing subscription rows arm their observers without waiting for an inbound message
/// against the relevant conversation.
actor ConnectionInvocationRuntime {
    private let store: any EnablementStore
    private let healthSubscriptionStore: (any HealthBackgroundSubscriptionStore)?
    private let healthGateway: (any HealthBackgroundDeliveryGateway)?
    private let healthBackfillReader: (any HealthBackfillReader)?
    private let healthDeltaReader: (any HealthDeltaReader)?
    private let healthRegistrar: (any HealthBackgroundObserverRegistrar)?

    private var lazyDelivery: XMTPConnectionDelivery?
    private var lazyHealthRouter: HealthInvocationRouter?
    private var bootstrapped: Bool = false

    init(
        store: any EnablementStore,
        healthSubscriptionStore: (any HealthBackgroundSubscriptionStore)? = nil,
        healthGateway: (any HealthBackgroundDeliveryGateway)? = nil,
        healthBackfillReader: (any HealthBackfillReader)? = nil,
        healthDeltaReader: (any HealthDeltaReader)? = nil,
        healthRegistrar: (any HealthBackgroundObserverRegistrar)? = nil
    ) {
        self.store = store
        self.healthSubscriptionStore = healthSubscriptionStore
        self.healthGateway = healthGateway
        self.healthBackfillReader = healthBackfillReader
        self.healthDeltaReader = healthDeltaReader
        self.healthRegistrar = healthRegistrar
    }

    func process(message: DecodedMessage, conversationId: String, client: any XMTPClientProvider) async {
        let delivery = ensureBootstrapped(client: client)

        if let router = lazyHealthRouter,
           let invocation = decodeInvocation(message: message),
           HealthInvocationRouter.intercepts(invocation) {
            await router.route(
                invocation: invocation,
                conversationId: conversationId,
                agentInboxId: message.senderInboxId
            )
            return
        }

        let manager = ConnectionsManager(
            sources: Self.makeSources(),
            sinks: Self.makeSinks(),
            store: store,
            delivery: delivery,
            deliveryObserver: nil,
            confirmationHandler: nil
        )
        let listener = XMTPInvocationListener(manager: manager, delivery: delivery)
        await listener.processIncoming(message: message, conversationId: conversationId)
    }

    private func ensureBootstrapped(client: any XMTPClientProvider) -> XMTPConnectionDelivery {
        if let lazyDelivery {
            return lazyDelivery
        }
        let provider = UncheckedSendableClient(client)
        let delivery = XMTPConnectionDelivery { conversationId in
            try await provider.value.conversationsProvider.findConversation(conversationId: conversationId)
        }
        self.lazyDelivery = delivery

        if let healthSubscriptionStore,
           let healthGateway,
           let healthBackfillReader,
           let healthDeltaReader,
           let healthRegistrar,
           !bootstrapped {
            bootstrapped = true
            let manager = HealthBackgroundSubscriptionManager(
                store: healthSubscriptionStore,
                gateway: healthGateway,
                reader: healthBackfillReader,
                delivery: delivery
            )
            let routine = HealthBackgroundObserverRoutine(
                store: healthSubscriptionStore,
                manager: manager,
                registrar: healthRegistrar,
                reader: healthDeltaReader,
                delivery: delivery
            )
            self.lazyHealthRouter = HealthInvocationRouter(
                enablementStore: store,
                manager: manager,
                routine: routine,
                delivery: delivery
            )
            Task { [routine] in
                do {
                    try await routine.start()
                } catch {
                    Log.error("Failed to start health observer routine: \(error.localizedDescription)")
                }
            }
        }

        return delivery
    }

    private nonisolated func decodeInvocation(message: DecodedMessage) -> ConnectionInvocation? {
        let encoded: EncodedContent
        do {
            encoded = try message.encodedContent
        } catch {
            return nil
        }
        guard encoded.type == ContentTypeConnectionInvocation else { return nil }
        return try? ConnectionInvocationCodec().decode(content: encoded)
    }

    private static func makeSources() -> [DataSource] {
        [
            CalendarDataSource(),
            ContactsDataSource(),
            PhotosDataSource(),
            HealthDataSource(),
            MusicDataSource(),
            HomeDataSource(),
            LocationDataSource(),
            MotionDataSource(),
        ]
    }

    private static func makeSinks() -> [DataSink] {
        [
            CalendarDataSink(),
            ContactsDataSink(),
            PhotosDataSink(),
            HealthDataSink(),
            MusicDataSink(),
            HomeKitDataSink(),
        ]
    }
}

private struct UncheckedSendableClient: @unchecked Sendable {
    let value: any XMTPClientProvider

    init(_ value: any XMTPClientProvider) {
        self.value = value
    }
}
