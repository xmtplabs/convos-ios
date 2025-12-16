import Combine
import Foundation

public enum MessagingServiceState {
    case registering, authorized(String)
}

extension MessagingServiceProtocol {
    public var state: MessagingServiceState {
        switch inboxStateManager.currentState {
        case .ready(_, let result):
            return .authorized(result.client.inboxId)
        default:
            return .registering
        }
    }
}

public protocol MessagingServiceProtocol: AnyObject {
    var clientId: String { get }
    var state: MessagingServiceState { get }
    var inboxStateManager: any InboxStateManagerProtocol { get }

    func stop()
    func stopAndDelete()
    func stopAndDelete() async

    func myProfileWriter() -> any MyProfileWriterProtocol

    func conversationStateManager() -> any ConversationStateManagerProtocol

    func conversationConsentWriter() -> any ConversationConsentWriterProtocol
    func conversationLocalStateWriter() -> any ConversationLocalStateWriterProtocol

    func messageWriter(for conversationId: String) -> any OutgoingMessageWriterProtocol

    func conversationMetadataWriter() -> any ConversationMetadataWriterProtocol
    func conversationPermissionsRepository() -> any ConversationPermissionsRepositoryProtocol

    func uploadImage(data: Data, filename: String) async throws -> String
    func uploadImageAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String
}

public extension MessagingServiceProtocol {
    var clientId: String {
        inboxStateManager.currentState.clientId
    }
}
