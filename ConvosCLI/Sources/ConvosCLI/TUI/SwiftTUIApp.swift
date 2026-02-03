import Combine
import ConvosCore
import Foundation
import SwiftTUI

// MARK: - Indexed Wrapper for ForEach with index

struct IndexedItem<T>: Identifiable {
    let id: Int
    let value: T

    init(index: Int, value: T) {
        self.id = index
        self.value = value
    }
}

extension Array {
    var indexed: [IndexedItem<Element>] {
        enumerated().map { IndexedItem(index: $0.offset, value: $0.element) }
    }
}

// MARK: - App State

final class TUIState: ObservableObject, @unchecked Sendable {
    @Published var screen: Screen = .conversationList
    @Published var conversations: [Conversation] = []
    @Published var messages: [AnyMessage] = []
    @Published var selectedIndex: Int = 0
    @Published var statusMessage: String = ""
    @Published var messageScrollOffset: Int = 0

    let context: CLIContext

    private var messageSubscription: AnyCancellable?

    enum Screen: Equatable {
        case conversationList
        case chat(conversationId: String, name: String)
        case joinPrompt
        case createPrompt
        case inviteQR(conversationId: String, name: String, inviteSlug: String)
    }

    init(context: CLIContext) {
        self.context = context
    }

    func loadConversations() {
        statusMessage = "Loading..."
        do {
            let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
            conversations = try repo.fetchAll()
            statusMessage = ""
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    func loadMessages(for conversationId: String) {
        statusMessage = "Loading messages..."
        do {
            let repo = context.session.messagesRepository(for: conversationId)
            messages = try repo.fetchInitial()
            messageScrollOffset = max(0, messages.count - 10)
            statusMessage = ""

            // Subscribe to updates
            messageSubscription?.cancel()
            messageSubscription = repo.messagesPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newMessages in
                    self?.messages = newMessages
                    self?.messageScrollOffset = max(0, newMessages.count - 10)
                }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    func unsubscribeFromMessages() {
        messageSubscription?.cancel()
        messageSubscription = nil
    }

    func openConversation(at index: Int) {
        guard index < conversations.count else { return }
        let conv = conversations[index]
        screen = .chat(conversationId: conv.id, name: conv.displayName)
        loadMessages(for: conv.id)
    }

    func goBack() {
        unsubscribeFromMessages()
        messages = []
        screen = .conversationList
        loadConversations()
    }

    func sendMessage(_ text: String, to conversationId: String) {
        guard !text.isEmpty else { return }

        statusMessage = "Sending..."

        Task {
            do {
                guard let conv = conversations.first(where: { $0.id == conversationId }) else {
                    statusMessage = "Error: Conversation not found"
                    return
                }

                let messagingService = try await context.session.messagingService(
                    for: conv.clientId,
                    inboxId: conv.inboxId
                )

                let writer = messagingService.messageWriter(for: conversationId)
                try await writer.send(text: text)

                statusMessage = ""
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    func joinConversation(invite: String) {
        statusMessage = "Joining..."

        Task {
            do {
                let inviteSlug = extractInviteSlug(from: invite)

                let messagingService = await context.session.addInbox()
                _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()

                let stateManager = messagingService.conversationStateManager()
                try await stateManager.joinConversation(inviteCode: inviteSlug)

                statusMessage = "Join request sent!"
                screen = .conversationList
                loadConversations()
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    func createConversation(name: String?) {
        statusMessage = "Creating..."

        Task {
            do {
                let messagingService = await context.session.addInbox()
                _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()

                let stateManager = messagingService.conversationStateManager()
                try await stateManager.createConversation()

                // Wait for ready state
                while true {
                    let state = stateManager.currentState
                    switch state {
                    case .ready(let result):
                        if let name = name, !name.isEmpty {
                            try await stateManager.conversationMetadataWriter.updateName(name, for: result.conversationId)
                        }
                        statusMessage = "Created!"
                        screen = .conversationList
                        loadConversations()
                        return

                    case .error(let error):
                        throw error

                    default:
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    func showInviteQR(conversationId: String, name: String) {
        statusMessage = "Loading invite..."

        Task {
            do {
                guard let conv = conversations.first(where: { $0.id == conversationId }) else {
                    statusMessage = "Error: Conversation not found"
                    return
                }

                _ = try await context.session.messagingService(
                    for: conv.clientId,
                    inboxId: conv.inboxId
                )

                let inviteRepo = context.session.inviteRepository(for: conversationId)
                let inviteSlug = try await waitForInvite(inviteRepo: inviteRepo)

                statusMessage = ""
                screen = .inviteQR(conversationId: conversationId, name: name, inviteSlug: inviteSlug)
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func waitForInvite(inviteRepo: any InviteRepositoryProtocol) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var hasResumed = false

            cancellable = inviteRepo.invitePublisher
                .compactMap { $0 }
                .first()
                .sink(
                    receiveCompletion: { completion in
                        guard !hasResumed else { return }
                        if case .failure(let error) = completion {
                            hasResumed = true
                            continuation.resume(throwing: error)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { invite in
                        guard !hasResumed else { return }
                        hasResumed = true
                        continuation.resume(returning: invite.urlSlug)
                        cancellable?.cancel()
                    }
                )
        }
    }

    private func extractInviteSlug(from invite: String) -> String {
        if let url = URL(string: invite),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let slugItem = queryItems.first(where: { $0.name == "i" }),
           let slug = slugItem.value {
            return slug
        }
        return invite
    }
}

// MARK: - Main App View

struct ConvosApp: View {
    @ObservedObject var state: TUIState

    var body: some View {
        switch state.screen {
        case .conversationList:
            ConversationListView(state: state)
        case let .chat(id, name):
            ChatView(state: state, conversationId: id, name: name)
        case .joinPrompt:
            JoinPromptView(state: state)
        case .createPrompt:
            CreatePromptView(state: state)
        case let .inviteQR(id, name, slug):
            InviteQRView(state: state, conversationId: id, name: name, inviteSlug: slug)
        }
    }
}

// MARK: - Conversation List View

struct ConversationListView: View {
    @ObservedObject var state: TUIState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Convos CLI").bold()
            Text("↑/↓ navigate  Enter open  n new  j join  r refresh  q quit")
                .foregroundColor(.gray)
            Divider()

            if state.conversations.isEmpty {
                Text("No conversations yet. Press 'n' to create or 'j' to join.")
                    .foregroundColor(.gray)
            } else {
                ForEach(state.conversations.indexed) { item in
                    let isSelected = item.id == state.selectedIndex

                    Button(item.value.displayName) {
                        state.openConversation(at: item.id)
                    }
                    .foregroundColor(isSelected ? .black : .default)
                    .background(isSelected ? .white : .default)
                }
            }

            Spacer()
            Divider()

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).foregroundColor(.yellow)
            } else {
                Text("\(state.conversations.count) conversations").foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var state: TUIState
    let conversationId: String
    let name: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(name).bold()
            Text("Esc back  Tab invite  Enter send")
                .foregroundColor(.gray)
            Divider()

            if state.messages.isEmpty {
                Text("No messages yet. Type something to start.")
                    .foregroundColor(.gray)
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(state.messages) { message in
                            MessageRow(message: message)
                        }
                    }
                }
            }

            Spacer()
            Divider()

            HStack {
                Text(">")
                TextField(placeholder: "Type a message...") { text in
                    state.sendMessage(text, to: conversationId)
                }
            }

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).foregroundColor(.yellow)
            }
        }
    }
}

struct MessageRow: View {
    let message: AnyMessage

    var body: some View {
        HStack {
            Text(message.base.sender.profile.displayName)
                .foregroundColor(.cyan)
            Text(formatTime(message.base.date))
                .foregroundColor(.gray)
            Text(":")
            Text(formatContent(message))
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatContent(_ message: AnyMessage) -> String {
        switch message.base.content {
        case .text(let text): return text
        case .emoji(let emoji): return emoji
        case .invite: return "[Invite]"
        case .attachment: return "[Attachment]"
        case .attachments(let urls): return "[Attachments: \(urls.count)]"
        case .update: return "[Group updated]"
        }
    }
}

// MARK: - Join Prompt View

struct JoinPromptView: View {
    @ObservedObject var state: TUIState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Join Conversation").bold()
            Divider()

            Text("")
            Text("Enter invite URL or slug:")
            HStack {
                Text(">")
                TextField(placeholder: "Paste invite here...") { text in
                    state.joinConversation(invite: text)
                }
            }
            Text("Press Enter to join, Esc to cancel").foregroundColor(.gray)

            Spacer()

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).foregroundColor(.yellow)
            }
        }
    }
}

// MARK: - Create Prompt View

struct CreatePromptView: View {
    @ObservedObject var state: TUIState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Create Conversation").bold()
            Divider()

            Text("")
            Text("Enter conversation name (optional):")
            HStack {
                Text(">")
                TextField(placeholder: "Conversation name...") { text in
                    state.createConversation(name: text.isEmpty ? nil : text)
                }
            }
            Text("Press Enter to create, Esc to cancel").foregroundColor(.gray)

            Spacer()

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).foregroundColor(.yellow)
            }
        }
    }
}

// MARK: - Invite QR View

struct InviteQRView: View {
    @ObservedObject var state: TUIState
    let conversationId: String
    let name: String
    let inviteSlug: String

    var body: some View {
        let inviteURL = "https://\(state.context.environment.inviteDomain)/v2?i=\(inviteSlug)"
        let qrLines = QRCode.render(from: inviteURL, label: nil)

        VStack {
            // Header
            VStack {
                Text("Invite to: \(name)").bold()
                Text("Esc back  c copy slug").foregroundColor(.gray)
                Divider()
            }

            Spacer()

            // QR code
            VStack {
                ForEach(qrLines, id: \.self) { line in
                    Text(line)
                }
            }

            // Info section
            VStack {
                Text("Scan QR or share link:").foregroundColor(.gray)
                Text(inviteURL).foregroundColor(.cyan)
                HStack {
                    Text("Slug:")
                    Text(inviteSlug).bold()
                }
            }

            Spacer()

            // Footer
            VStack {
                Divider()
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage).foregroundColor(.yellow)
                }
            }
        }
    }
}

// MARK: - TUI Runner

func runSwiftTUI(context: CLIContext) {
    let state = TUIState(context: context)
    state.loadConversations()

    let app = Application(rootView: ConvosApp(state: state))
    app.start()
}
