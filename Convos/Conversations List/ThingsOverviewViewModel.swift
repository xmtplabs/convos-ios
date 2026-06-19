import Combine
import ConvosCore
import Foundation

/// One cell in the cross-conversation Things grid: a single agent-sent
/// HTML attachment in `conversation`, plus enough info to render the
/// preview thumbnail and the convo's display name + unread dot under it.
/// A conversation may contribute several items (one per distinct HTML
/// thing), so the identity is the message id, not the conversation id.
struct ThingOverviewItem: Identifiable, Hashable {
    let conversation: Conversation
    /// Message id of the attachment send; unique per thing so multiple
    /// things from the same conversation get distinct grid cells.
    let messageId: String
    /// Inbox id of the agent that sent the attachment, so the detail
    /// view's indicator can open that agent's contact card.
    let senderInboxId: String
    let attachmentKey: String
    let filename: String?
    let mimeType: String?
    let thumbnailDataBase64: String?
    let date: Date

    var id: String { messageId }

    var hydratedAttachment: HydratedAttachment {
        HydratedAttachment(
            key: attachmentKey,
            mimeType: mimeType,
            thumbnailDataBase64: thumbnailDataBase64,
            filename: filename
        )
    }
}

/// View model for the Things tab's cross-conversation grid. Subscribes to
/// the conversations list and, for each conversation, to that convo's
/// `AgentFilesLinksRepository.filesPublisher` so we can pull out every
/// HTML file (the repository already dedupes re-sends of the same
/// filename). Builds a flat, date-sorted array of [[ThingOverviewItem]]
/// for the grid to render, so a single conversation can contribute
/// multiple cells.
///
/// One subscription per conversation is acceptable scale for v1; if list
/// sizes ever grow past a couple hundred conversations the right next
/// move is a single SQL query that joins the message + conversation
/// tables and returns the latest HTML attachment per conversation in one
/// shot.
@MainActor
@Observable
final class ThingsOverviewViewModel {
    var items: [ThingOverviewItem] = []

    @ObservationIgnored private let session: any SessionManagerProtocol
    @ObservationIgnored private var conversationsCancellable: AnyCancellable?
    @ObservationIgnored private var filesCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var conversationsById: [String: Conversation] = [:]
    @ObservationIgnored private var htmlFilesPerConvo: [String: [AgentFile]] = [:]
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
            htmlFilesPerConvo.removeValue(forKey: id)
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
                let htmlFiles = files.filter { isHTML($0) }
                if htmlFiles.isEmpty {
                    self.htmlFilesPerConvo.removeValue(forKey: conversationId)
                } else {
                    self.htmlFilesPerConvo[conversationId] = htmlFiles
                }
                self.rebuildItems()
            }
    }

    private func isHTML(_ file: AgentFile) -> Bool {
        if file.mimeType?.lowercased() == "text/html" { return true }
        return file.filename?.lowercased().hasSuffix(".html") ?? false
    }

    private func rebuildItems() {
        items = htmlFilesPerConvo.flatMap { id, files -> [ThingOverviewItem] in
            guard let convo = conversationsById[id] else { return [] }
            return files.map { (file: AgentFile) -> ThingOverviewItem in
                ThingOverviewItem(
                    conversation: convo,
                    messageId: file.id,
                    senderInboxId: file.senderInboxId,
                    attachmentKey: file.attachmentKey,
                    filename: file.filename,
                    mimeType: file.mimeType,
                    thumbnailDataBase64: file.thumbnailDataBase64,
                    date: file.date
                )
            }
        }
        .sorted { $0.date > $1.date }
    }
}
