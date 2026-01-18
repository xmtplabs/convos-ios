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
    /// Thread-safe snapshot of the repository's loading state
    private struct LoadingState {
        let seenIds: Set<String>
        let isInitial: Bool
        let isPaginating: Bool
    }
    private let dbReader: any DatabaseReader
    private var conversationId: String {
        conversationIdSubject.value
    }
    private let conversationIdSubject: CurrentValueSubject<String, Never>
    private var conversationIdCancellable: AnyCancellable?

    // Pagination properties
    private let pageSize: Int
    private let currentLimitSubject: CurrentValueSubject<Int, Never>
    private var currentLimit: Int {
        get { currentLimitSubject.value }
        set { currentLimitSubject.send(newValue) }
    }

    // Thread-safe synchronization queue for mutable state
    private let stateQueue: DispatchQueue = DispatchQueue(label: "com.convos.MessagesRepository.stateQueue")

    /// Indicates if there are more messages to load
    private var _hasMoreMessages: Bool = true
    var hasMoreMessages: Bool {
        stateQueue.sync { _hasMoreMessages }
    }

    /// Tracks message IDs that have been seen (existing messages)
    /// Any new message not in this set is considered "inserted"
    /// When messages are loaded again, previously inserted messages become existing
    private var _seenMessageIds: Set<String> = []
    private var seenMessageIds: Set<String> {
        get { stateQueue.sync { _seenMessageIds } }
        set { stateQueue.sync(flags: .barrier) { self._seenMessageIds = newValue } }
    }

    /// Tracks whether we've completed the initial load
    /// Used to differentiate between initial/pagination loads vs new message insertions
    private var _hasCompletedInitialLoad: Bool = false
    private var hasCompletedInitialLoad: Bool {
        get { stateQueue.sync { _hasCompletedInitialLoad } }
        set { stateQueue.sync(flags: .barrier) { self._hasCompletedInitialLoad = newValue } }
    }

    /// Tracks whether we're currently loading via fetchPrevious
    /// Used to ensure paginated messages are marked as .existing
    private var _isLoadingPrevious: Bool = false
    private var isLoadingPrevious: Bool {
        get { stateQueue.sync { _isLoadingPrevious } }
        set { stateQueue.sync(flags: .barrier) { self._isLoadingPrevious = newValue } }
    }

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

            // Emit the new conversationId first
            self.conversationIdSubject.send(conversationId)

            // Now perform the initial read, which will reset state properly
            do {
                _ = try self.fetchInitial()
            } catch {
                Log.error("Failed fetching initial messages after conversation change: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        conversationIdCancellable?.cancel()
    }

    func fetchInitial() throws -> [AnyMessage] {
        // Reset all state synchronously before performing the read
        stateQueue.sync(flags: .barrier) {
            self._hasMoreMessages = true
            self._seenMessageIds.removeAll()
            self._hasCompletedInitialLoad = false
        }

        // Reset to initial page size synchronously
        currentLimit = pageSize

        return try dbReader.read { [weak self] db in
            guard let self else { return [] }

            // Get current state safely (should be empty after reset)
            let currentSeenIds = self.stateQueue.sync { self._seenMessageIds }

            // Pass isInitialLoad = true to mark all messages as .existing
            let (messages, updatedSeenIds) = try db.composeMessages(
                for: self.conversationId,
                limit: self.currentLimit,
                seenMessageIds: currentSeenIds,
                isInitialLoad: true,
                isPaginating: false
            )

            // Update state atomically
            self.stateQueue.sync(flags: .barrier) {
                self._seenMessageIds = updatedSeenIds
                self._hasCompletedInitialLoad = true
                // Check if we got fewer messages than the page size
                if messages.count < self.pageSize {
                    self._hasMoreMessages = false
                }
            }

            return messages
        }
    }

    func fetchPrevious() throws {
        // Capture the current conversation ID and calculate target limit before any async operations
        // This prevents race conditions with conversation changes
        let capturedConversationId = conversationId
        let targetLimit = currentLimit + pageSize

        // Synchronously check and acquire the pagination lock
        // This ensures only one pagination operation can proceed at a time
        let shouldProceed = stateQueue.sync { () -> Bool in
            // Check if we can proceed with pagination
            guard !_isLoadingPrevious && _hasMoreMessages else {
                return false
            }
            // Atomically set the loading flag before any state changes
            _isLoadingPrevious = true
            return true
        }

        // Early return if we shouldn't proceed (already loading or no more messages)
        guard shouldProceed else { return }

        // Ensure we always reset the loading flag, even if the read throws
        defer {
            stateQueue.sync(flags: .barrier) {
                self._isLoadingPrevious = false
            }
        }

        // Increment the limit
        currentLimit = targetLimit

        // The publisher will automatically update with the new messages
        try dbReader.read { [weak self] db in
            guard let self else { return }

            let totalCount = try DBMessage
                .filter(DBMessage.Columns.conversationId == capturedConversationId)
                .fetchCount(db)

            self.stateQueue.sync(flags: .barrier) {
                // Verify the conversation hasn't changed before updating state
                // If it has changed, abort without updating state as this pagination
                // was for the previous conversation
                guard self.conversationId == capturedConversationId else {
                    return
                }

                if totalCount <= targetLimit {
                    self._hasMoreMessages = false
                }
            }
        }
    }

    lazy var conversationMessagesPublisher: AnyPublisher<ConversationMessages, Never> = {
        let dbReader = dbReader
        let stateQueue = stateQueue
        // Combine both conversation ID and limit changes
        return Publishers.CombineLatest(
            conversationIdSubject.removeDuplicates(),
            currentLimitSubject.removeDuplicates()
        )
        .map { [weak self] conversationId, limit -> AnyPublisher<ConversationMessages, Never> in
            guard let self else {
                return Just((conversationId, [])).eraseToAnyPublisher()
            }

            // Capture unsafe self reference for use in @Sendable tracking closure.
            // This is safe because:
            // 1. The outer closure already has a weak self guard
            // 2. GRDB's ValueObservation is bound to the lifecycle of this publisher
            // 3. The publisher is invalidated when self is deallocated
            nonisolated(unsafe) let unsafeSelf = self

            return ValueObservation
                .tracking { db in
                    do {
                        // Get current state safely
                        let currentState = stateQueue.sync { () -> LoadingState in
                            LoadingState(
                                seenIds: unsafeSelf._seenMessageIds,
                                isInitial: !unsafeSelf._hasCompletedInitialLoad,
                                isPaginating: unsafeSelf._isLoadingPrevious
                            )
                        }

                        let (messages, updatedSeenIds) = try db.composeMessages(
                            for: conversationId,
                            limit: limit,
                            seenMessageIds: currentState.seenIds,
                            isInitialLoad: currentState.isInitial,
                            isPaginating: currentState.isPaginating
                        )

                        // Update seenMessageIds atomically
                        stateQueue.sync(flags: .barrier) {
                            unsafeSelf._seenMessageIds = updatedSeenIds
                        }

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
            let reactions = try dbReactions.hydrateReactions(from: database, in: conversation)
            switch dbMessage.messageType {
            case .original:
                let messageContent: MessageContent
                switch dbMessage.contentType {
                case .text:
                    messageContent = .text(dbMessage.text ?? "")
                case .invite:
                    guard let invite = dbMessage.invite else {
                        Log.error("Invite message type is missing invite object")
                        return nil
                    }
                    messageContent = .invite(invite)
                case .attachments:
                    messageContent = .attachments(dbMessage.attachmentUrls.compactMap { urlString in
                        URL(string: urlString)
                    })
                case .emoji:
                    messageContent = .emoji(dbMessage.emoji ?? "")
                case .update:
                    guard let update = dbMessage.update,
                          let initiatedByMember = try DBConversationMemberProfileWithRole.fetchOne(
                            database,
                            conversationId: conversation.id,
                            inboxId: update.initiatedByInboxId
                          ) else {
                        Log.error("Update message type is missing update object")
                        return nil
                    }
                    let addedMembers = try DBConversationMemberProfileWithRole.fetchAll(
                        database,
                        conversationId: conversation.id,
                        inboxIds: update.addedInboxIds
                    )
                    let removedMembers = try DBConversationMemberProfileWithRole.fetchAll(
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
                case .text, .invite:
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
                case .text, .attachments, .update, .invite:
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

private extension Array where Element == DBMessage {
    func hydrateReactions(from database: Database, in conversation: Conversation) throws -> [MessageReaction] {
        try compactMap { dbReaction -> MessageReaction? in
            guard let reactionSenderProfile = try DBConversationMemberProfileWithRole.fetchOne(
                database,
                conversationId: conversation.id,
                inboxId: dbReaction.senderId
            ) else {
                Log.warning("Reaction dropped: missing sender profile for inboxId \(dbReaction.senderId)")
                return nil
            }
            let reactionSender = reactionSenderProfile.hydrateConversationMember(currentInboxId: conversation.inboxId)
            let reactionSource: MessageSource = reactionSender.isCurrentUser ? .outgoing : .incoming
            return MessageReaction(
                id: dbReaction.clientMessageId,
                conversation: conversation,
                sender: reactionSender,
                source: reactionSource,
                status: dbReaction.status,
                content: .emoji(dbReaction.emoji ?? ""),
                date: dbReaction.date,
                emoji: dbReaction.emoji ?? ""
            )
        }
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
