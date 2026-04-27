import Combine
import Foundation

public protocol DraftConversationWriterProtocol: OutgoingMessageWriterProtocol {
    var conversationId: String { get }
    var conversationIdPublisher: AnyPublisher<String, Never> { get }
    var conversationMetadataWriter: any ConversationMetadataWriterProtocol { get }

    func createConversation() async throws
    func joinConversation(inviteCode: String) async throws
}
