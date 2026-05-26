import Combine
import ConvosCore
import Foundation

/// One cell in the cross-conversation Stuff grid: the most recent
/// agent-sent HTML attachment in `conversation`, plus enough info to
/// render the preview thumbnail and the convo's display name + unread
/// dot under it.
struct StuffOverviewItem: Identifiable, Hashable {
    let conversation: Conversation
    let attachmentKey: String
    let filename: String?
    let mimeType: String?
    let thumbnailDataBase64: String?
    let date: Date

    var id: String { conversation.id }

    var hydratedAttachment: HydratedAttachment {
        HydratedAttachment(
            key: attachmentKey,
            mimeType: mimeType,
            thumbnailDataBase64: thumbnailDataBase64,
            filename: filename
        )
    }
}

/// View model for the Stuff tab's cross-conversation grid. Subscribes to
/// the conversations list and, for each conversation, to that convo's
/// `AgentFilesLinksRepository.filesPublisher` so we can pull out the
/// latest HTML file. Builds a deduped, date-sorted array of
/// [[StuffOverviewItem]] for the grid to render.
///
/// One subscription per conversation is acceptable scale for v1; if list
/// sizes ever grow past a couple hundred conversations the right next
/// move is a single SQL query that joins the message + conversation
/// tables and returns the latest HTML attachment per conversation in one
/// shot.
@MainActor
@Observable
final class StuffOverviewViewModel {
    var items: [StuffOverviewItem] = []

    @ObservationIgnored private let session: any SessionManagerProtocol
    @ObservationIgnored private var conversationsCancellable: AnyCancellable?
    @ObservationIgnored private var filesCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var conversationsById: [String: Conversation] = [:]
    @ObservationIgnored private var latestHTMLPerConvo: [String: AgentFile] = [:]
    @ObservationIgnored private let conversationsRepository: any ConversationsRepositoryProtocol

    init(session: any SessionManagerProtocol) {
        self.session = session
        self.conversationsRepository = session.conversationsRepository(for: .allowed)
        subscribeToConversations()
    }

    private func subscribeToConversations() {
        conversationsCancellable = conversationsRepository.conversationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] convos in
                self?.handleConversations(convos)
            }
    }

    private func handleConversations(_ convos: [Conversation]) {
        conversationsById = Dictionary(uniqueKeysWithValues: convos.map { ($0.id, $0) })

        let activeIds = Set(convos.map(\.id))
        let removedIds = Set(filesCancellables.keys).subtracting(activeIds)
        for id in removedIds {
            filesCancellables.removeValue(forKey: id)
            latestHTMLPerConvo.removeValue(forKey: id)
        }
        for convo in convos where filesCancellables[convo.id] == nil {
            subscribeToFiles(for: convo.id)
        }
        rebuildItems()
    }

    private func subscribeToFiles(for conversationId: String) {
        let repo = session.agentFilesLinksRepository(for: conversationId)
        filesCancellables[conversationId] = repo.filesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] files in
                guard let self else { return }
                let htmlFile = files.first { isHTML($0) }
                if let htmlFile {
                    self.latestHTMLPerConvo[conversationId] = htmlFile
                } else {
                    self.latestHTMLPerConvo.removeValue(forKey: conversationId)
                }
                self.rebuildItems()
            }
    }

    private func isHTML(_ file: AgentFile) -> Bool {
        if file.mimeType?.lowercased() == "text/html" { return true }
        return file.filename?.lowercased().hasSuffix(".html") ?? false
    }

    private func rebuildItems() {
        items = latestHTMLPerConvo.compactMap { id, file -> StuffOverviewItem? in
            guard let convo = conversationsById[id] else { return nil }
            return StuffOverviewItem(
                conversation: convo,
                attachmentKey: file.attachmentKey,
                filename: file.filename,
                mimeType: file.mimeType,
                thumbnailDataBase64: file.thumbnailDataBase64,
                date: file.date
            )
        }
        .sorted { $0.date > $1.date }
    }
}
