import Combine
import ConvosCore
import Foundation
import Observation

@MainActor
@Observable
final class ConversationPickerViewModel {
    var conversations: [Conversation] = []
    var query: String = ""

    private let repository: any ConversationsRepositoryProtocol
    @ObservationIgnored private var cancellable: AnyCancellable?

    init(session: any SessionManagerProtocol) {
        self.repository = session.conversationsRepository(for: .allowed)
        self.conversations = ((try? repository.fetchAll()) ?? []).filter { !$0.isAgentDm }
        cancellable = repository.conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                self?.conversations = conversations.filter { !$0.isAgentDm }
            }
    }

    var filteredConversations: [Conversation] {
        let trimmed: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.computedDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
