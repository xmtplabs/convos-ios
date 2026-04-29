import ConvosConnections
import ConvosConnectionsXMTP
import Foundation
@preconcurrency import XMTPiOS

actor ConnectionInvocationRuntime {
    private let store: any EnablementStore

    init(store: any EnablementStore) {
        self.store = store
    }

    func process(message: DecodedMessage, conversationId: String, client: any XMTPClientProvider) async {
        let provider = UncheckedSendableClient(client)
        let delivery = XMTPConnectionDelivery { conversationId in
            try await provider.value.conversationsProvider.findConversation(conversationId: conversationId)
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
