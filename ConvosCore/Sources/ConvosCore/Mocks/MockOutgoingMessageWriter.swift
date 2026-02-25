import Combine
import Foundation

/// Mock implementation of OutgoingMessageWriterProtocol for testing
public final class MockOutgoingMessageWriter: OutgoingMessageWriterProtocol, @unchecked Sendable {
    private let sentMessageSubject: PassthroughSubject = PassthroughSubject<String, Never>()
    public var sentMessages: [String] = []
    public var sentImageCount: Int = 0

    public init() {}

    public var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    public func send(text: String) async throws {
        let messageId = UUID().uuidString
        sentMessages.append(text)
        sentMessageSubject.send(messageId)
    }

    public func send(text: String, afterPhoto trackingKey: String?) async throws {
        try await send(text: text)
    }

    public func send(image: ImageType) async throws {
        sentImageCount += 1
        let mockURL = "https://example.com/photos/mock_photo_\(sentImageCount).jpg"
        sentMessageSubject.send(mockURL)
    }

    public func startEagerUpload(image: ImageType) async throws -> String {
        UUID().uuidString
    }

    public func sendEagerPhoto(trackingKey: String) async throws {
        sentImageCount += 1
        let mockURL = "https://example.com/photos/mock_photo_\(sentImageCount).jpg"
        sentMessageSubject.send(mockURL)
    }

    public func cancelEagerUpload(trackingKey: String) async {}

    public func sendReply(text: String, toMessageWithClientId parentClientMessageId: String) async throws {
        try await send(text: text)
    }

    public func sendEagerPhotoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws {
        try await sendEagerPhoto(trackingKey: trackingKey)
    }

    public func sendReply(text: String, afterPhoto trackingKey: String?, toMessageWithClientId parentClientMessageId: String) async throws {
        try await send(text: text, afterPhoto: trackingKey)
    }
}
