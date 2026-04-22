import Combine
import Foundation
import GRDB
import UniformTypeIdentifiers

public struct ConversationMessagesResult: Sendable {
    public let conversationId: String
    public let messages: [AnyMessage]
    public let readReceipts: [ReadReceiptEntry]
    public let memberProfiles: [String: MemberProfileInfo]
}

public struct MemberProfileInfo: Sendable {
    public let inboxId: String
    public let conversationId: String
    public let name: String?
    public let avatar: String?

    public init(inboxId: String, conversationId: String, name: String?, avatar: String?) {
        self.inboxId = inboxId
        self.conversationId = conversationId
        self.name = name
        self.avatar = avatar
    }
}

public protocol MessagesRepositoryProtocol {
    var messagesPublisher: AnyPublisher<[AnyMessage], Never> { get }
    var conversationMessagesResultPublisher: AnyPublisher<ConversationMessagesResult, Never> { get }

    func fetchInitial() throws -> [AnyMessage]
    func fetchInitialResult() throws -> ConversationMessagesResult
    func fetchPrevious() throws

    var hasMoreMessages: Bool { get }
}

extension MessagesRepositoryProtocol {
    var messagesPublisher: AnyPublisher<[AnyMessage], Never> {
        conversationMessagesResultPublisher
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

    /// Caller-supplied identity for the "is this message from me?" decision.
    /// Passing the current-user inbox id at init avoids a fragile lookup
    /// through `conversation.members` that silently flipped every bubble to
    /// `.incoming` when the member list hadn't loaded yet.
    private let currentInboxId: String

    /// Synchronous helper for call sites that need to construct a
    /// `MessagesRepository` but don't already have an inbox id in scope.
    /// Returns an empty string when no identity is registered yet (e.g.
    /// the split second between fresh install and first session bootstrap);
    /// in that window there are no messages anyway, so the unoccupied slot
    /// is harmless.
    static func currentInboxId(from dbReader: any DatabaseReader) -> String {
        (try? dbReader.read { db in
            try DBInbox.fetchAll(db).first?.inboxId
        }) ?? ""
    }

    init(
        dbReader: any DatabaseReader,
        conversationId: String,
        currentInboxId: String,
        pageSize: Int = 50
    ) {
        self.dbReader = dbReader
        self.conversationIdSubject = .init(conversationId)
        self.currentInboxId = currentInboxId
        self.pageSize = pageSize
        self.currentLimitSubject = .init(pageSize)
    }

    init(
        dbReader: any DatabaseReader,
        conversationId: String,
        currentInboxId: String,
        conversationIdPublisher: AnyPublisher<String, Never>,
        pageSize: Int = 25
    ) {
        self.dbReader = dbReader
        self.conversationIdSubject = .init(conversationId)
        self.currentInboxId = currentInboxId
        self.pageSize = pageSize
        self.currentLimitSubject = .init(pageSize)
        conversationIdCancellable = conversationIdPublisher
            .dropFirst()
            .sink { [weak self] conversationId in
                guard let self else { return }
                Log.debug("Sending updated conversation id: \(conversationId), resetting pagination")

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
                currentInboxId: self.currentInboxId,
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

    func fetchInitialResult() throws -> ConversationMessagesResult {
        stateQueue.sync(flags: .barrier) {
            self._hasMoreMessages = true
            self._seenMessageIds.removeAll()
            self._hasCompletedInitialLoad = false
        }

        currentLimit = pageSize

        return try dbReader.read { [weak self] db in
            guard let self else {
                return ConversationMessagesResult(conversationId: self?.conversationId ?? "", messages: [], readReceipts: [], memberProfiles: [:])
            }

            let currentSeenIds = self.stateQueue.sync { self._seenMessageIds }

            let (messages, updatedSeenIds) = try db.composeMessages(
                for: self.conversationId,
                currentInboxId: self.currentInboxId,
                limit: self.currentLimit,
                seenMessageIds: currentSeenIds,
                isInitialLoad: true,
                isPaginating: false
            )

            self.stateQueue.sync(flags: .barrier) {
                self._seenMessageIds = updatedSeenIds
                self._hasCompletedInitialLoad = true
                if messages.count < self.pageSize {
                    self._hasMoreMessages = false
                }
            }

            let readReceipts = try DBConversationReadReceipt
                .filter(DBConversationReadReceipt.Columns.conversationId == self.conversationId)
                .fetchAll(db)
                .map { ReadReceiptEntry(inboxId: $0.inboxId, readAtNs: $0.readAtNs) }

            let profiles = try Self.fetchMemberProfiles(db, conversationId: self.conversationId)

            return ConversationMessagesResult(
                conversationId: self.conversationId,
                messages: messages,
                readReceipts: readReceipts,
                memberProfiles: profiles
            )
        }
    }

    func fetchPrevious() throws {
        // Capture the current conversation ID and calculate target limit before any async operations
        // This prevents race conditions with conversation changes
        let capturedConversationId = conversationId
        let targetLimit = currentLimit + pageSize

        // Synchronously check and acquire the pagination lock
        // This ensures only one pagination operation can proceed at a time.
        // The flag is cleared from the ValueObservation closure once the
        // publisher re-emits with the new limit, not here — otherwise the
        // async observation would see a stale _isLoadingPrevious and mark
        // paginated messages as .inserted / .existing instead of .paginated.
        let shouldProceed = stateQueue.sync { () -> Bool in
            guard !_isLoadingPrevious && _hasMoreMessages else {
                return false
            }
            _isLoadingPrevious = true
            return true
        }

        guard shouldProceed else { return }

        // Check if there are more messages to load before bumping the limit.
        // If not, clear the loading flag and bail out.
        let totalCount = try dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == capturedConversationId)
                .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
                .fetchCount(db)
        }

        let shouldBumpLimit = stateQueue.sync(flags: .barrier) { () -> Bool in
            guard self.conversationId == capturedConversationId else {
                self._isLoadingPrevious = false
                return false
            }
            if totalCount <= currentLimit {
                self._hasMoreMessages = false
                self._isLoadingPrevious = false
                return false
            }
            if totalCount <= targetLimit {
                self._hasMoreMessages = false
            }
            return true
        }

        guard shouldBumpLimit else { return }

        // Increment the limit. The publisher will re-emit with the new limit
        // and the ValueObservation closure will clear _isLoadingPrevious.
        currentLimit = targetLimit
    }

    lazy var conversationMessagesResultPublisher: AnyPublisher<ConversationMessagesResult, Never> = {
        let dbReader = dbReader
        let stateQueue = stateQueue
        return Publishers.CombineLatest(
            conversationIdSubject.removeDuplicates(),
            currentLimitSubject.removeDuplicates()
        )
        .map { [weak self] conversationId, limit -> AnyPublisher<ConversationMessagesResult, Never> in
            guard let self else {
                return Just(ConversationMessagesResult(conversationId: conversationId, messages: [], readReceipts: [], memberProfiles: [:]))
                    .eraseToAnyPublisher()
            }

            nonisolated(unsafe) let unsafeSelf = self

            return ValueObservation
                .tracking { db in
                    do {
                        let allLocalStates = try AttachmentLocalState.fetchAll(db)

                        let currentState = stateQueue.sync { () -> LoadingState in
                            LoadingState(
                                seenIds: unsafeSelf._seenMessageIds,
                                isInitial: !unsafeSelf._hasCompletedInitialLoad,
                                isPaginating: unsafeSelf._isLoadingPrevious
                            )
                        }

                        let (messages, updatedSeenIds) = try db.composeMessages(
                            for: conversationId,
                            currentInboxId: unsafeSelf.currentInboxId,
                            limit: limit,
                            prefetchedLocalStates: allLocalStates,
                            seenMessageIds: currentState.seenIds,
                            isInitialLoad: currentState.isInitial,
                            isPaginating: currentState.isPaginating
                        )

                        // Update seenMessageIds atomically and clear the pagination flag.
                        // Clearing here (after messages have been composed with the updated
                        // limit) ensures origin is correctly set to .paginated for newly
                        // loaded messages before the UI observes them.
                        stateQueue.sync(flags: .barrier) {
                            unsafeSelf._seenMessageIds = updatedSeenIds
                            if currentState.isPaginating {
                                unsafeSelf._isLoadingPrevious = false
                            }
                        }

                        let readReceipts = try DBConversationReadReceipt
                            .filter(DBConversationReadReceipt.Columns.conversationId == conversationId)
                            .fetchAll(db)
                            .map { ReadReceiptEntry(inboxId: $0.inboxId, readAtNs: $0.readAtNs) }

                        let profiles = try MessagesRepository.fetchMemberProfiles(db, conversationId: conversationId)

                        return ConversationMessagesResult(
                            conversationId: conversationId,
                            messages: messages,
                            readReceipts: readReceipts,
                            memberProfiles: profiles
                        )
                    } catch {
                        Log.error("Error in messages publisher: \(error)")
                    }
                    return ConversationMessagesResult(conversationId: conversationId, messages: [], readReceipts: [], memberProfiles: [:])
                }
                .publisher(in: dbReader)
                .replaceError(with: ConversationMessagesResult(conversationId: conversationId, messages: [], readReceipts: [], memberProfiles: [:]))
                .eraseToAnyPublisher()
        }
        .switchToLatest()
        .eraseToAnyPublisher()
    }()

    static func fetchMemberProfiles(_ db: Database, conversationId: String) throws -> [String: MemberProfileInfo] {
        let rows = try DBMemberProfile
            .filter(DBMemberProfile.Columns.conversationId == conversationId)
            .fetchAll(db)
        var result: [String: MemberProfileInfo] = [:]
        for row in rows {
            result[row.inboxId] = MemberProfileInfo(
                inboxId: row.inboxId,
                conversationId: conversationId,
                name: row.name,
                avatar: row.avatar
            )
        }
        return result
    }
}

extension Array where Element == DBMessage {
    func composeMessages(in conversation: Conversation,
                         currentInboxId: String,
                         memberProfileCache: MemberProfileCache,
                         reactionsBySourceId: [String: [DBMessage]],
                         sourceMessagesById: [String: DBMessage],
                         attachmentLocalStates: [String: AttachmentLocalState] = [:],
                         expiredInviteSlugs: Set<String> = [],
                         seenMessageIds: Set<String>,
                         isInitialLoad: Bool = false,
                         isPaginating: Bool = false) -> ([AnyMessage], Set<String>) {
        var updatedSeenIds = seenMessageIds

        let messages = compactMap { dbMessage -> AnyMessage? in
            let sender = memberProfileCache.member(for: dbMessage.senderId)
                ?? ConversationMember(
                    profile: .empty(inboxId: dbMessage.senderId),
                    role: .member,
                    isCurrentUser: !currentInboxId.isEmpty && dbMessage.senderId == currentInboxId
                )
            let source: MessageSource = sender.isCurrentUser ? .outgoing : .incoming
            let reactions = (reactionsBySourceId[dbMessage.id] ?? []).hydrateReactions(
                cache: memberProfileCache
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
                    let resolvedInvite = expiredInviteSlugs.contains(invite.inviteSlug)
                        ? invite.with(isConversationExpired: true)
                        : invite
                    messageContent = .invite(resolvedInvite)
                case .linkPreview:
                    guard let preview = dbMessage.linkPreview else {
                        messageContent = .text(dbMessage.text ?? "")
                        break
                    }
                    messageContent = .linkPreview(preview)
                case .attachments:
                    let hydratedAttachments = dbMessage.attachmentUrls.map { key in
                        hydrateAttachment(key: key, localState: attachmentLocalStates[key])
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
                                isCurrentUser: !currentInboxId.isEmpty && inboxId == currentInboxId
                            )
                    }
                    var metadataChanges: [ConversationUpdate.MetadataChange] = update.metadataChanges
                        .map {
                            .init(
                                field: .init(rawValue: $0.field) ?? .unknown,
                                oldValue: $0.oldValue,
                                newValue: $0.newValue
                            )
                        }
                    if let expiresAt = update.expiresAt {
                        let originalDuration = ExplosionDurationFormatter.format(
                            from: dbMessage.date,
                            until: expiresAt
                        )
                        metadataChanges.append(.init(
                            field: .expiresAt,
                            oldValue: originalDuration,
                            newValue: expiresAt.ISO8601Format()
                        ))
                    }
                    messageContent = .update(
                        .init(
                            creator: initiatedByMember,
                            addedMembers: addedMembers,
                            removedMembers: removedMembers,
                            metadataChanges: metadataChanges
                        )
                    )
                case .assistantJoinRequest:
                    let status = AssistantJoinStatus(rawValue: dbMessage.text ?? "pending") ?? .pending
                    messageContent = .assistantJoinRequest(status: status, requestedByInboxId: dbMessage.senderId)
                }

                let message = Message(
                    id: dbMessage.clientMessageId,
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
                    memberProfileCache: memberProfileCache,
                    attachmentLocalStates: attachmentLocalStates,
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
        memberProfileCache: MemberProfileCache,
        attachmentLocalStates: [String: AttachmentLocalState],
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
            replyContent = .attachments(dbMessage.attachmentUrls.map { key in
                hydrateAttachment(key: key, localState: attachmentLocalStates[key])
            })
        case .invite:
            if let invite = dbMessage.invite {
                replyContent = .invite(invite)
            } else {
                replyContent = .text(dbMessage.text ?? "")
            }
        case .linkPreview:
            if let preview = dbMessage.linkPreview {
                replyContent = .linkPreview(preview)
            } else {
                replyContent = .text(dbMessage.text ?? "")
            }
        case .update, .assistantJoinRequest:
            return nil
        }

        guard let sourceDBMessage = sourceMessage,
              let parentSender = memberProfileCache.member(for: sourceDBMessage.senderId) else {
            let message = Message(
                id: dbMessage.clientMessageId,
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
            parentContent = .attachments(sourceDBMessage.attachmentUrls.map { key in
                hydrateAttachment(key: key, localState: attachmentLocalStates[key])
            })
        case .invite:
            if let invite = sourceDBMessage.invite {
                parentContent = .invite(invite)
            } else {
                parentContent = .text("[Invite]")
            }
        case .linkPreview:
            if let preview = sourceDBMessage.linkPreview {
                parentContent = .linkPreview(preview)
            } else {
                parentContent = .text(sourceDBMessage.text ?? "")
            }
        case .update, .assistantJoinRequest:
            parentContent = .text("[Update]")
        }

        let parentMessage = Message(
            id: sourceDBMessage.clientMessageId,
            sender: parentSender, source: parentSource, status: sourceDBMessage.status,
            content: parentContent, date: sourceDBMessage.date, reactions: []
        )

        let messageReply = MessageReply(
            id: dbMessage.clientMessageId,
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

    init(
        activeProfiles: [DBConversationMemberProfileWithRole],
        allProfiles: [DBMemberProfile],
        currentInboxId: String
    ) {
        var map: [String: ConversationMember] = [:]
        map.reserveCapacity(max(activeProfiles.count, allProfiles.count))

        for profile in activeProfiles {
            map[profile.memberProfile.inboxId] = profile.hydrateConversationMember(currentInboxId: currentInboxId)
        }

        for profile in allProfiles where map[profile.inboxId] == nil {
            map[profile.inboxId] = ConversationMember(
                profile: profile.hydrateProfile(),
                role: .member,
                isCurrentUser: profile.inboxId == currentInboxId,
                isAgent: profile.isAgent,
                agentVerification: profile.agentVerification
            )
        }

        profilesByInboxId = map
    }

    func member(for inboxId: String) -> ConversationMember? {
        profilesByInboxId[inboxId]
    }
}

private extension Array where Element == DBMessage {
    func hydrateReactions(
        cache: MemberProfileCache
    ) -> [MessageReaction] {
        compactMap { dbReaction -> MessageReaction? in
            guard let reactionSender = cache.member(for: dbReaction.senderId) else {
                Log.warning("Reaction dropped: missing sender profile for inboxId \(dbReaction.senderId)")
                return nil
            }
            let reactionSource: MessageSource = reactionSender.isCurrentUser ? .outgoing : .incoming
            return MessageReaction(
                id: dbReaction.clientMessageId,
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
    func fetchLightweightConversation(for conversationId: String, currentInboxId: String) throws -> Conversation? {
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
                    .select([
                        DBConversationMember.Columns.role,
                        DBConversationMember.Columns.createdAt,
                    ])
                    .including(required: DBConversationMember.memberProfile)
                    .including(optional: DBConversationMember.inviterProfile)
            )
            .asRequest(of: LightweightConversationDetails.self)
            .fetchOne(self)?
            .hydrateConversation(currentInboxId: currentInboxId)
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
    func hydrateConversation(currentInboxId: String) -> Conversation {
        let members = conversationMembers.map {
            $0.hydrateConversationMember(currentInboxId: currentInboxId)
        }
        let creator: ConversationMember
        if let creatorDetails = conversationCreator, let profile = creatorDetails.memberProfile {
            let hydratedProfile = profile.hydrateProfile()
            let isAgent = profile.isAgent
            creator = ConversationMember(
                profile: hydratedProfile,
                role: creatorDetails.role,
                isCurrentUser: profile.inboxId == currentInboxId,
                isAgent: isAgent,
                agentVerification: profile.agentVerification
            )
        } else {
            creator = ConversationMember(
                profile: .empty(inboxId: conversation.creatorId),
                role: .superAdmin,
                isCurrentUser: conversation.creatorId == currentInboxId
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
            conversationEmoji: conversation.conversationEmoji,
            includeInfoInPublicPreview: conversation.includeInfoInPublicPreview,
            isDraft: conversation.isDraft,
            invite: nil,
            expiresAt: conversation.expiresAt,
            debugInfo: conversation.debugInfo,
            isLocked: conversation.isLocked,
            assistantJoinStatus: nil,
            hasHadVerifiedAssistant: conversation.hasHadVerifiedAssistant
        )
    }
}

fileprivate extension Database {
    func composeMessages(
        for conversationId: String,
        currentInboxId: String,
        limit: Int? = nil,
        prefetchedLocalStates: [AttachmentLocalState]? = nil,
        seenMessageIds: Set<String>,
        isInitialLoad: Bool = false,
        isPaginating: Bool = false
    ) throws -> ([AnyMessage], Set<String>) {
        guard let conversation = try fetchLightweightConversation(
            for: conversationId,
            currentInboxId: currentInboxId
        ) else {
            return ([], .init())
        }

        let activeMemberProfiles = try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .select([
                DBConversationMember.Columns.role,
                DBConversationMember.Columns.createdAt,
            ])
            .including(required: DBConversationMember.memberProfile)
            .including(optional: DBConversationMember.inviterProfile)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchAll(self)

        let historicalMemberProfiles = try DBMemberProfile
            .filter(DBMemberProfile.Columns.conversationId == conversationId)
            .fetchAll(self)

        let memberProfileCache = MemberProfileCache(
            activeProfiles: activeMemberProfiles,
            allProfiles: historicalMemberProfiles,
            currentInboxId: currentInboxId
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

        let localStates: [AttachmentLocalState]
        if let prefetchedLocalStates {
            localStates = prefetchedLocalStates
        } else {
            let allAttachmentKeys = rawMessages.flatMap { $0.attachmentUrls }
                + sourceMessagesById.values.flatMap { $0.attachmentUrls }
            if !allAttachmentKeys.isEmpty {
                localStates = try AttachmentLocalState
                    .filter(allAttachmentKeys.contains(AttachmentLocalState.Columns.attachmentKey))
                    .fetchAll(self)
            } else {
                localStates = []
            }
        }
        let attachmentLocalStates = Dictionary(uniqueKeysWithValues: localStates.map { ($0.attachmentKey, $0) })

        let inviteSlugs = Set(rawMessages.compactMap { $0.invite?.inviteSlug })
        let expiredInviteSlugs = try fetchExpiredInviteSlugs(from: inviteSlugs)

        let chronologicalMessages = rawMessages.reversed()
        let result = Array(chronologicalMessages).composeMessages(
            in: conversation,
            currentInboxId: currentInboxId,
            memberProfileCache: memberProfileCache,
            reactionsBySourceId: reactionsBySourceId,
            sourceMessagesById: sourceMessagesById,
            attachmentLocalStates: attachmentLocalStates,
            expiredInviteSlugs: expiredInviteSlugs,
            seenMessageIds: seenMessageIds,
            isInitialLoad: isInitialLoad,
            isPaginating: isPaginating
        )
        return result
    }

    /// Returns the subset of `slugs` whose linked `DBConversation` has already
    /// expired. Used to flag inline side-convo invite rows as "Exploded" in the
    /// parent conversation's message stream. Side convos the local inbox never
    /// joined (and therefore has no local `DBInvite` for) are absent from the
    /// result — those invites continue to render as live.
    func fetchExpiredInviteSlugs(from slugs: Set<String>) throws -> Set<String> {
        guard !slugs.isEmpty else { return [] }
        let now = Date()
        let rows = try DBInvite
            .filter(slugs.contains(DBInvite.Columns.urlSlug))
            .fetchAll(self)
        guard !rows.isEmpty else { return [] }

        let conversationIds = Set(rows.map(\.conversationId))
        let expiredConversationIds = try DBConversation
            .filter(conversationIds.contains(DBConversation.Columns.id))
            .filter(DBConversation.Columns.expiresAt != nil)
            .filter(DBConversation.Columns.expiresAt < now)
            .fetchAll(self)
            .map(\.id)
        let expiredSet = Set(expiredConversationIds)
        return Set(rows.filter { expiredSet.contains($0.conversationId) }.map(\.urlSlug))
    }
}

private func hydrateAttachment(key: String, localState: AttachmentLocalState?) -> HydratedAttachment {
    var mimeType: String? = localState?.mimeType
    var duration: Double?
    var thumbnailDataBase64: String?
    var width: Int? = localState?.width
    var height: Int? = localState?.height

    var filename: String?

    if let stored = try? StoredRemoteAttachment.fromJSON(key) {
        if mimeType == nil { mimeType = stored.mimeType }
        if width == nil { width = stored.mediaWidth }
        if height == nil { height = stored.mediaHeight }
        duration = stored.mediaDuration
        thumbnailDataBase64 = stored.thumbnailDataBase64
        filename = stored.filename
    } else if key.hasPrefix("file://") {
        let url = URL(string: key) ?? URL(fileURLWithPath: String(key.dropFirst(7)))
        let name = url.lastPathComponent
        if let underscoreIndex = name.firstIndex(of: "_") {
            filename = String(name[name.index(after: underscoreIndex)...])
        } else {
            filename = name
        }
        if mimeType == nil, let ext = filename.flatMap({ ($0 as NSString).pathExtension.lowercased() }),
           !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            mimeType = utType.preferredMIMEType
        }
    }

    var waveformLevels: [Float]?
    if let levelsJSON = localState?.waveformLevels,
       let data = levelsJSON.data(using: .utf8),
       let decoded = try? JSONDecoder().decode([Float].self, from: data) {
        waveformLevels = decoded
    }

    if duration == nil {
        duration = localState?.duration
    }

    return HydratedAttachment(
        key: key,
        isRevealed: localState?.isRevealed ?? false,
        isHiddenByOwner: localState?.isHiddenByOwner ?? false,
        width: width,
        height: height,
        mimeType: mimeType,
        duration: duration,
        thumbnailDataBase64: thumbnailDataBase64,
        filename: filename,
        waveformLevels: waveformLevels
    )
}
