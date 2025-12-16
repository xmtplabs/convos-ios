import Combine
import Foundation

/// Mock implementation of OutgoingMessageWriterProtocol for testing
public final class MockOutgoingMessageWriter: OutgoingMessageWriterProtocol, @unchecked Sendable {
    private let sentMessageSubject: PassthroughSubject = PassthroughSubject<String, Never>()
    public var sentMessages: [String] = []

    public init() {}

    public var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    public func send(text: String) async throws {
        let messageId = UUID().uuidString
        sentMessages.append(text)
        sentMessageSubject.send(messageId)
    }
}
