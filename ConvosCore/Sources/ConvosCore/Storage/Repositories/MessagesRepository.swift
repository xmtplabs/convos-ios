import Combine
import Foundation
import GRDB

public typealias ConversationMessages = (conversationId: String, messages: [AnyMessage])

public protocol MessagesRepositoryProtocol {
    var messagesPublisher: AnyPublisher<[AnyMessage], Never> { get }
    var conversationMessagesPublisher: AnyPublisher<ConversationMessages, Never> { get }

    /// Fetches the initial page of messages (most recent messages)
    /// Resets the pagination cursor to fetch only the latest messages
    func fetchInitial() throws -> [AnyMessage]

    /// Fetches previous (older) messages by increasing the limit
    /// Each call increases the limit by the page size
    /// Results are delivered through the publisher
    func fetchPrevious() throws

    /// Indicates if there are more messages to load
    /// Automatically set to false when fetchPrevious returns fewer messages than the page size
    var hasMoreMessages: Bool { get }
}

extension MessagesRepositoryProtocol {
    var messagesPublisher: AnyPublisher<[AnyMessage], Never> {
        conversationMessagesPublisher
            .map { $0.messages }
            .eraseToAnyPublisher()
    }
}

/// Repository for managing paginated message fetching and observation
///
/// This repository implements a simple pagination strategy:
/// - Starts by fetching the N most recent messages (where N = pageSize)
/// - Each call to fetchPrevious() increases the limit by pageSize
/// - The publisher automatically updates when the limit changes
/// - When conversation changes, pagination resets to the initial page
///
/// Note: Currently, when loading previous messages, all messages up to the new limit
/// are re-composed. This could be optimized in the future to only compose new messages.
class MessagesRepository: MessagesRepositoryProtocol {
    private let dbReader: any DatabaseReader
    private var conversationId: String {
        conversationIdSubject.value
    }
    private let conversationIdSubject: CurrentValueSubject<String, Never>
    private let messages: [AnyMessage] = []
    private var conversationIdCancellable: AnyCancellable?

    // Pagination properties
    private let pageSize: Int
    private let currentLimitSubject: CurrentValueSubject<Int, Never>
    private var currentLimit: Int {
        get { currentLimitSubject.value }
        set { currentLimitSubject.send(newValue) }
    }

    /// Indicates if there are more messages to load
    private(set) var hasMoreMessages: Bool = true

    /// Tracks message IDs that have been seen (existing messages)
    /// Any new message not in this set is considered "inserted"
    /// When messages are loaded again, previously inserted messages become existing
    private var seenMessageIds: Set<String> = []

    /// Tracks whether we've completed the initial load
    /// Used to differentiate between initial/pagination loads vs new message insertions
    private var hasCompletedInitialLoad: Bool = false

    /// Tracks whether we're currently loading via fetchPrevious
    /// Used to ensure paginated messages are marked as .existing
    private var isLoadingPrevious: Bool = false

    init(dbReader: any DatabaseReader, conversationId: String, pageSize: Int = 150) {
        self.dbReader = dbReader
        self.conversationIdSubject = .init(conversationId)
        self.pageSize = pageSize
        self.currentLimitSubject = .init(pageSize)
    }

    init(dbReader: any DatabaseReader,
         conversationId: String,
         conversationIdPublisher: AnyPublisher<String, Never>,
         pageSize: Int = 25) {
        self.dbReader = dbReader
        self.conversationIdSubject = .init(conversationId)
        self.pageSize = pageSize
        self.currentLimitSubject = .init(pageSize)
        conversationIdCancellable = conversationIdPublisher.sink { [weak self] conversationId in
            guard let self else { return }
            Log.info("Sending updated conversation id: \(conversationId), resetting pagination")
            // Reset pagination and origin tracking when conversation changes
            seenMessageIds.removeAll()
            isLoadingPrevious = false
            do {
                _ = try fetchInitial()
            } catch {
                Log.error("Failed fetching initial messages after conversation change: \(error.localizedDescription)")
            }

            conversationIdSubject.send(conversationId)
        }
    }

    deinit {
        conversationIdCancellable?.cancel()
    }

    func fetchInitial() throws -> [AnyMessage] {
        // Reset to initial page size and assume more messages are available
        currentLimit = pageSize
        hasMoreMessages = true
        // Clear seenMessageIds for fresh start
        seenMessageIds.removeAll()
        hasCompletedInitialLoad = false

        return try dbReader.read { [weak self] db in
            guard let self else { return [] }
            // Pass isInitialLoad = true to mark all messages as .existing
            let (messages, updatedSeenIds) = try db.composeMessages(for: conversationId, limit: currentLimit, seenMessageIds: seenMessageIds, isInitialLoad: true, isPaginating: false)

            // Update seen IDs
            self.seenMessageIds = updatedSeenIds

            // Mark initial load as complete
            hasCompletedInitialLoad = true

            // Check if we got fewer messages than the page size
            if messages.count < pageSize {
                hasMoreMessages = false
            }

            return messages
        }
    }

    func fetchPrevious() throws {
        // Don't fetch if we already know there are no more messages
        guard hasMoreMessages else { return }

        // Set flag to indicate we're loading previous messages
        isLoadingPrevious = true

        // Increase the limit by pageSize to load more messages
        currentLimit += pageSize

        // The publisher will automatically update with the new messages
        // Check if we need to update hasMoreMessages
        try dbReader.read { [weak self] db in
            guard let self else { return }

            let totalCount = try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .fetchCount(db)

            if totalCount <= currentLimit {
                hasMoreMessages = false
            }
        }

        // Reset the flag after triggering the update
        // The publisher will pick up the flag value before we reset it
        DispatchQueue.main.async { [weak self] in
            self?.isLoadingPrevious = false
        }
    }

    lazy var conversationMessagesPublisher: AnyPublisher<ConversationMessages, Never> = {
        // Combine both conversation ID and limit changes
        Publishers.CombineLatest(
            conversationIdSubject.removeDuplicates(),
            currentLimitSubject.removeDuplicates()
        )
        .map { [weak self] conversationId, limit -> AnyPublisher<ConversationMessages, Never> in
            guard let self else {
                return Just((conversationId, [])).eraseToAnyPublisher()
            }

            return ValueObservation
                .tracking { [weak self] db in
                    guard let self else { return [] }
                    do {
                        // Determine the context of this load
                        let isInitialLoad = !self.hasCompletedInitialLoad
                        let isPaginating = self.isLoadingPrevious
                        let (messages, updatedSeenIds) = try db.composeMessages(
                            for: conversationId,
                            limit: limit,
                            seenMessageIds: self.seenMessageIds,
                            isInitialLoad: isInitialLoad,
                            isPaginating: isPaginating
                        )
                        self.seenMessageIds = updatedSeenIds
                        return messages
                    } catch {
                        Log.error("Error in messages publisher: \(error)")
                    }
                    return []
                }
                .publisher(in: dbReader)
                .replaceError(with: [])
                .map { (conversationId, $0) }
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        .eraseToAnyPublisher()
    }()
}

extension Array where Element == MessageWithDetails {
    func composeMessages(from database: Database,
                         in conversation: Conversation,
                         seenMessageIds: Set<String>,
                         isInitialLoad: Bool = false,
                         isPaginating: Bool = false) throws -> ([AnyMessage], Set<String>) {
        let dbMessagesWithDetails = self
        var updatedSeenIds = seenMessageIds

        let messages = try dbMessagesWithDetails.compactMap { dbMessageWithDetails -> AnyMessage? in
            let dbMessage = dbMessageWithDetails.message
            let dbReactions = dbMessageWithDetails.messageReactions
            let dbSender = dbMessageWithDetails.messageSender

            let sender = dbSender.hydrateConversationMember(currentInboxId: conversation.inboxId)
            let source: MessageSource = sender.isCurrentUser ? .outgoing : .incoming
            let reactions: [MessageReaction] = dbReactions.map {
                .init(
                    id: $0.clientMessageId,
                    conversation: conversation,
                    sender: sender,
                    source: source,
                    status: $0.status,
                    content: .emoji($0.emoji ?? ""),
                    date: Date(),
                    emoji: $0.emoji ?? ""
                )
            }
            switch dbMessage.messageType {
            case .original:
                let messageContent: MessageContent
                switch dbMessage.contentType {
                case .text:
                    messageContent = .text(dbMessage.text ?? "")
                case .attachments:
                    messageContent = .attachments(dbMessage.attachmentUrls.compactMap { urlString in
                        URL(string: urlString)
                    })
                case .emoji:
                    messageContent = .emoji(dbMessage.emoji ?? "")
                case .update:
                    guard let update = dbMessage.update,
                          let initiatedByMember = try ConversationMemberProfileWithRole.fetchOne(
                            database,
                            conversationId: conversation.id,
                            inboxId: update.initiatedByInboxId
                          ) else {
                        Log.error("Update message type is missing update object")
                        return nil
                    }
                    let addedMembers = try ConversationMemberProfileWithRole.fetchAll(
                        database,
                        conversationId: conversation.id,
                        inboxIds: update.addedInboxIds
                    )
                    let removedMembers = try ConversationMemberProfileWithRole.fetchAll(
                        database,
                        conversationId: conversation.id,
                        inboxIds: update.removedInboxIds
                    )
                    messageContent = .update(
                        .init(
                            creator: initiatedByMember.hydrateConversationMember(currentInboxId: conversation.inboxId),
                            addedMembers: addedMembers.map { $0.hydrateConversationMember(currentInboxId: conversation.inboxId) },
                            removedMembers: removedMembers.map { $0.hydrateConversationMember(currentInboxId: conversation.inboxId) },
                            metadataChanges: update.metadataChanges
                                .map {
                                    .init(
                                        field: .init(rawValue: $0.field) ?? .unknown,
                                        oldValue: $0.oldValue,
                                        newValue: $0.newValue
                                    )
                                }
                        )
                    )
                }

                let message = Message(
                    id: dbMessage.clientMessageId,
                    conversation: conversation,
                    sender: sender,
                    source: source,
                    status: dbMessage.status,
                    content: messageContent,
                    date: dbMessage.date,
                    reactions: reactions
                )

                // Determine origin:
                // - Initial load: all messages are .existing
                // - Pagination: unseen messages are .paginated, seen are .existing
                // - New insertions: unseen messages are .inserted, seen are .existing
                let origin: AnyMessage.Origin
                if isInitialLoad {
                    // Initial load - all are existing
                    origin = .existing
                } else if isPaginating {
                    // Pagination - unseen messages are paginated, seen are existing
                    origin = seenMessageIds.contains(dbMessage.clientMessageId) ? .existing : .paginated
                } else {
                    // New insertions - unseen messages are inserted, seen are existing
                    origin = seenMessageIds.contains(dbMessage.clientMessageId) ? .existing : .inserted
                }

                // Add to seen messages
                updatedSeenIds.insert(dbMessage.clientMessageId)

                return .message(message, origin)
            case .reply:
                switch dbMessage.contentType {
                case .text:
                    break
                case .attachments:
                    break
                case .emoji:
                    break
                case .update:
                    return nil
                }

            case .reaction:
                switch dbMessage.contentType {
                case .text, .attachments, .update:
                    // invalid
                    return nil
                case .emoji:
                    break
                }
            }

            return nil
        }

        return (messages, updatedSeenIds)
    }
}

fileprivate extension Database {
    func composeMessages(
        for conversationId: String,
        limit: Int? = nil,
        seenMessageIds: Set<String>,
        isInitialLoad: Bool = false,
        isPaginating: Bool = false
    ) throws -> ([AnyMessage], Set<String>) {
        guard let dbConversationDetails = try DBConversation
            .filter(DBConversation.Columns.id == conversationId)
            .detailedConversationQuery()
            .fetchOne(self) else {
            return ([], .init())
        }

        let conversation = dbConversationDetails.hydrateConversation()

        // Build the query
        var query = DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .order(\.dateNs.desc) // Order by DESC to get the latest messages first

        // Apply limit if provided (gets the N most recent messages)
        if let limit = limit {
            query = query.limit(limit)
        }

        let dbMessages = try query
            .including(
                required: DBMessage.sender
                    .forKey("messageSender")
                    .select([DBConversationMember.Columns.role])
                    .including(required: DBConversationMember.memberProfile)
            )
            .including(all: DBMessage.reactions)
            // .including(all: DBMessage.replies)
            .including(optional: DBMessage.sourceMessage)
            .asRequest(of: MessageWithDetails.self)
            .fetchAll(self)

        // Reverse the messages back to chronological order after fetching
        // since we fetched them in reverse order to get the latest N messages
        let chronologicalMessages = dbMessages.reversed()
        return try Array(chronologicalMessages).composeMessages(
            from: self,
            in: conversation,
            seenMessageIds: seenMessageIds,
            isInitialLoad: isInitialLoad,
            isPaginating: isPaginating
        )
    }
}
