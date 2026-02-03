import Foundation
@preconcurrency import XMTPiOS

public final class MockMessageStreamProvider: MessageStreamProviderProtocol, @unchecked Sendable {
    private var messagesToYield: [StreamedMessage] = []

    public init() {}

    public func setMessagesToYield(_ messages: [StreamedMessage]) {
        messagesToYield = messages
    }

    public func stream(
        consentStates: [ConsentState]?
    ) -> AsyncThrowingStream<StreamedMessage, Error> {
        let messages = messagesToYield
        return AsyncThrowingStream { continuation in
            Task {
                for message in messages {
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }
    }
}
