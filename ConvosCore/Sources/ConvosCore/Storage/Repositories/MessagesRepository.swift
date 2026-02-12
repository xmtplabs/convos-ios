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

    init(dbReader: any DatabaseReader, conversationId: String, pageSize: Int = 50) {
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
        conversationIdCancellable = conversationIdPublisher
            .dropFirst()
            .sink { [weak self] conversationId in
                guard let self else { return }
                Log.info("Sending updated conversation id: \(conversationId), resetting pagination")

                self.conversationIdSubject.send(conversationId)

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

        let result = try dbReader.read { [weak self] db in
            guard let self else { return [AnyMessage]() }

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
        return result
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
                .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
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
                        // Force tracking of AttachmentLocalState table so changes
                        // to reveal/hide state trigger re-emission of messages
                        let localStateCount = try AttachmentLocalState.fetchCount(db)
                        let allLocalStates = try AttachmentLocalState.fetchAll(db)
                        let revealedKeys = allLocalStates.filter { $0.isRevealed }.map { $0.attachmentKey }
                        Log.info("[MessagesRepo] Observation triggered. LocalState count: \(localStateCount), revealed: \(revealedKeys)")

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

extension Array where Element == DBMessage {
    func composeMessages(in conversation: Conversation,
                         memberProfileCache: MemberProfileCache,
                         reactionsBySourceId: [String: [DBMessage]],
                         sourceMessagesById: [String: DBMessage],
                         seenMessageIds: Set<String>,
                         isInitialLoad: Bool = false,
                         isPaginating: Bool = false) -> ([AnyMessage], Set<String>) {
        var updatedSeenIds = seenMessageIds

        let messages = compactMap { dbMessage -> AnyMessage? in
            guard let sender = memberProfileCache.member(for: dbMessage.senderId) else {
                Log.warning("Message dropped: missing sender profile for inboxId \(dbMessage.senderId)")
                return nil
            }
            let source: MessageSource = sender.isCurrentUser ? .outgoing : .incoming
            let reactions = (reactionsBySourceId[dbMessage.id] ?? []).hydrateReactions(
                cache: memberProfileCache,
                conversation: conversation
            )
            let origin = Self.resolveOrigin(
                for: dbMessage.clientMessageId,
                seenMessageIds: seenMessageIds,
                isInitialLoad: isInitialLoad,
                isPaginating: isPaginating
            )
            updatedSeenIds.insert(dbMessage.clientMessageId)

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
                    let hydratedAttachments = dbMessage.attachmentUrls.map { key in
                        HydratedAttachment(key: key)
                    }
                    messageContent = .attachments(hydratedAttachments)
                case .emoji:
                    messageContent = .emoji(dbMessage.emoji ?? "")
                case .update:
                    guard let update = dbMessage.update,
                          let initiatedByMember = memberProfileCache.member(for: update.initiatedByInboxId) else {
                        Log.error("Update message type is missing update object")
                        return nil
                    }
                    let addedMembers = update.addedInboxIds.compactMap { memberProfileCache.member(for: $0) }
                    let removedMembers = update.removedInboxIds.map { inboxId in
                        memberProfileCache.member(for: inboxId)
                            ?? ConversationMember(
                                profile: .empty(inboxId: inboxId),
                                role: .member,
                                isCurrentUser: inboxId == conversation.inboxId
                            )
                    }
                    messageContent = .update(
                        .init(
                            creator: initiatedByMember,
                            addedMembers: addedMembers,
                            removedMembers: removedMembers,
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
                return .message(message, origin)
            case .reply:
                let sourceMessage = dbMessage.sourceMessageId.flatMap { sourceMessagesById[$0] }
                return Self.composeReplyMessage(
                    sourceMessage: sourceMessage, dbMessage: dbMessage,
                    in: conversation, memberProfileCache: memberProfileCache,
                    sender: sender, source: source, reactions: reactions, origin: origin
                )
            case .reaction:
                return nil
            }
        }

        return (messages, updatedSeenIds)
    }

    // swiftlint:disable:next function_parameter_count
    private static func composeReplyMessage(
        sourceMessage: DBMessage?,
        dbMessage: DBMessage,
        in conversation: Conversation,
        memberProfileCache: MemberProfileCache,
        sender: ConversationMember,
        source: MessageSource,
        reactions: [MessageReaction],
        origin: AnyMessage.Origin
    ) -> AnyMessage? {
        let replyContent: MessageContent
        switch dbMessage.contentType {
        case .text:
            replyContent = .text(dbMessage.text ?? "")
        case .emoji:
            replyContent = .emoji(dbMessage.emoji ?? "")
        case .attachments:
            replyContent = .attachments(dbMessage.attachmentUrls.map { HydratedAttachment(key: $0) })
        case .update, .invite:
            return nil
        }

        guard let sourceDBMessage = sourceMessage,
              let parentSender = memberProfileCache.member(for: sourceDBMessage.senderId) else {
            let message = Message(
                id: dbMessage.clientMessageId, conversation: conversation,
                sender: sender, source: source, status: dbMessage.status,
                content: replyContent, date: dbMessage.date, reactions: reactions
            )
            return .message(message, origin)
        }

        let parentSource: MessageSource = parentSender.isCurrentUser ? .outgoing : .incoming
        let parentContent: MessageContent
        switch sourceDBMessage.contentType {
        case .text:
            parentContent = .text(sourceDBMessage.text ?? "")
        case .emoji:
            parentContent = .emoji(sourceDBMessage.emoji ?? "")
        case .attachments:
            parentContent = .attachments(sourceDBMessage.attachmentUrls.map { HydratedAttachment(key: $0) })
        case .invite:
            if let invite = sourceDBMessage.invite {
                parentContent = .invite(invite)
            } else {
                parentContent = .text("[Invite]")
            }
        case .update:
            parentContent = .text("[Update]")
        }

        let parentMessage = Message(
            id: sourceDBMessage.clientMessageId, conversation: conversation,
            sender: parentSender, source: parentSource, status: sourceDBMessage.status,
            content: parentContent, date: sourceDBMessage.date, reactions: []
        )

        let messageReply = MessageReply(
            id: dbMessage.clientMessageId, conversation: conversation,
            sender: sender, source: source, status: dbMessage.status,
            content: replyContent, date: dbMessage.date,
            parentMessage: parentMessage, reactions: reactions
        )
        return .reply(messageReply, origin)
    }

    private static func resolveOrigin(
        for messageId: String,
        seenMessageIds: Set<String>,
        isInitialLoad: Bool,
        isPaginating: Bool
    ) -> AnyMessage.Origin {
        if isInitialLoad {
            return .existing
        } else if isPaginating {
            return seenMessageIds.contains(messageId) ? .existing : .paginated
        } else {
            return seenMessageIds.contains(messageId) ? .existing : .inserted
        }
    }
}

// MARK: - MemberProfileCache

struct MemberProfileCache {
    private let profilesByInboxId: [String: ConversationMember]

    init(profiles: [DBConversationMemberProfileWithRole], currentInboxId: String) {
        var map: [String: ConversationMember] = [:]
        map.reserveCapacity(profiles.count)
        for profile in profiles {
            map[profile.memberProfile.inboxId] = profile.hydrateConversationMember(currentInboxId: currentInboxId)
        }
        self.profilesByInboxId = map
    }

    func member(for inboxId: String) -> ConversationMember? {
        profilesByInboxId[inboxId]
    }
}

private extension Array where Element == DBMessage {
    func hydrateReactions(
        cache: MemberProfileCache,
        conversation: Conversation
    ) -> [MessageReaction] {
        compactMap { dbReaction -> MessageReaction? in
            guard let reactionSender = cache.member(for: dbReaction.senderId) else {
                Log.warning("Reaction dropped: missing sender profile for inboxId \(dbReaction.senderId)")
                return nil
            }
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

// MARK: - Lightweight Conversation Query for Message Composition

fileprivate extension Database {
    func fetchLightweightConversation(for conversationId: String) throws -> Conversation? {
        try DBConversation
            .filter(DBConversation.Columns.id == conversationId)
            .including(
                optional: DBConversation.creator
                    .forKey("conversationCreator")
                    .select([DBConversationMember.Columns.role])
                    .including(optional: DBConversationMember.memberProfile)
            )
            .including(required: DBConversation.localState)
            .including(
                all: DBConversation._members
                    .forKey("conversationMembers")
                    .select([DBConversationMember.Columns.role])
                    .including(required: DBConversationMember.memberProfile)
            )
            .asRequest(of: LightweightConversationDetails.self)
            .fetchOne(self)?
            .hydrateConversation()
    }
}

private struct LightweightCreatorDetails: Codable, FetchableRecord, Hashable {
    let memberProfile: DBMemberProfile?
    let role: MemberRole
}

private struct LightweightConversationDetails: Codable, FetchableRecord, Hashable {
    let conversation: DBConversation
    let conversationCreator: LightweightCreatorDetails?
    let conversationMembers: [DBConversationMemberProfileWithRole]
    let conversationLocalState: ConversationLocalState
}

private extension LightweightConversationDetails {
    func hydrateConversation() -> Conversation {
        let members = conversationMembers.map {
            $0.hydrateConversationMember(currentInboxId: conversation.inboxId)
        }
        let creator: ConversationMember
        if let creatorDetails = conversationCreator, let profile = creatorDetails.memberProfile {
            creator = ConversationMember(
                profile: profile.hydrateProfile(),
                role: creatorDetails.role,
                isCurrentUser: profile.inboxId == conversation.inboxId
            )
        } else {
            creator = ConversationMember(
                profile: .empty(inboxId: conversation.creatorId),
                role: .superAdmin,
                isCurrentUser: conversation.creatorId == conversation.inboxId
            )
        }
        let otherMember: ConversationMember?
        if conversation.kind == .dm,
           let other = members.first(where: { !$0.isCurrentUser }) {
            otherMember = other
        } else {
            otherMember = nil
        }
        let imageURL: URL?
        if let imageURLString = conversation.imageURLString {
            imageURL = URL(string: imageURLString)
        } else {
            imageURL = nil
        }
        return Conversation(
            id: conversation.id,
            clientConversationId: conversation.clientConversationId,
            inboxId: conversation.inboxId,
            clientId: conversation.clientId,
            creator: creator,
            createdAt: conversation.createdAt,
            consent: conversation.consent,
            kind: conversation.kind,
            name: conversation.name,
            description: conversation.description,
            members: members,
            otherMember: otherMember,
            messages: [],
            isPinned: conversationLocalState.isPinned,
            isUnread: conversationLocalState.isUnread,
            isMuted: conversationLocalState.isMuted,
            pinnedOrder: conversationLocalState.pinnedOrder,
            lastMessage: nil,
            imageURL: imageURL,
            imageSalt: conversation.imageSalt,
            imageNonce: conversation.imageNonce,
            imageEncryptionKey: conversation.imageEncryptionKey,
            includeInfoInPublicPreview: conversation.includeInfoInPublicPreview,
            isDraft: conversation.isDraft,
            invite: nil,
            expiresAt: conversation.expiresAt,
            debugInfo: conversation.debugInfo,
            isLocked: conversation.isLocked
        )
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
        guard let conversation = try fetchLightweightConversation(for: conversationId) else {
            return ([], .init())
        }

        let allMemberProfiles = try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .select([DBConversationMember.Columns.role])
            .including(required: DBConversationMember.memberProfile)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchAll(self)
        let memberProfileCache = MemberProfileCache(
            profiles: allMemberProfiles,
            currentInboxId: conversation.inboxId
        )

        var query = DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
            .order(DBMessage.Columns.sortId.desc)

        if let limit {
            query = query.limit(limit)
        }

        let rawMessages = try query.fetchAll(self)

        let messageIds = rawMessages.map { $0.id }
        let replySourceIds = rawMessages.compactMap { $0.messageType == .reply ? $0.sourceMessageId : nil }

        var reactionsBySourceId: [String: [DBMessage]] = [:]
        if !messageIds.isEmpty {
            let allReactions = try DBMessage
                .filter(messageIds.contains(DBMessage.Columns.sourceMessageId))
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchAll(self)
            for reaction in allReactions {
                guard let sourceId = reaction.sourceMessageId else { continue }
                reactionsBySourceId[sourceId, default: []].append(reaction)
            }
        }

        var sourceMessagesById: [String: DBMessage] = [:]
        if !replySourceIds.isEmpty {
            let uniqueSourceIds = Array(Set(replySourceIds))
            let sourceMessages = try DBMessage
                .filter(uniqueSourceIds.contains(DBMessage.Columns.id))
                .fetchAll(self)
            for msg in sourceMessages {
                sourceMessagesById[msg.id] = msg
            }
        }

        let chronologicalMessages = rawMessages.reversed()
        let result = Array(chronologicalMessages).composeMessages(
            in: conversation,
            memberProfileCache: memberProfileCache,
            reactionsBySourceId: reactionsBySourceId,
            sourceMessagesById: sourceMessagesById,
            seenMessageIds: seenMessageIds,
            isInitialLoad: isInitialLoad,
            isPaginating: isPaginating
        )
        return result
    }
}
