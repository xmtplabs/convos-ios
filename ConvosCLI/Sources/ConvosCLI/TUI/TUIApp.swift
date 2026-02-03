import Combine
import ConvosCore
import Foundation

/// Main TUI application
@MainActor
final class TUIApp {
    enum Screen {
        case conversationList
        case chat(conversationId: String, name: String)
        case joinPrompt
        case createPrompt
        case inviteQR(conversationId: String, name: String, inviteSlug: String)
        case deleteConfirm(conversationId: String, name: String, clientId: String, inboxId: String)
    }

    private let context: CLIContext
    private let keyReader: KeyReader
    private let lineEditor: LineEditor

    private var currentScreen: Screen = .conversationList
    private var conversations: [Conversation] = []
    private var selectedIndex: Int = 0
    private var messages: [AnyMessage] = []
    private var messageScrollOffset: Int = 0
    private var isRunning: Bool = true
    private var statusMessage: String = ""
    private var promptInput: String = ""

    // Message streaming
    private var messageSubscription: AnyCancellable?
    private var pendingMessages: [AnyMessage]?

    init(context: CLIContext) {
        self.context = context
        self.keyReader = KeyReader()
        self.lineEditor = LineEditor()
    }

    func run() async throws {
        // Setup terminal
        keyReader.enableRawMode()
        Terminal.enterAlternateScreen()
        Terminal.hideCursor()

        defer {
            messageSubscription?.cancel()
            Terminal.showCursor()
            Terminal.leaveAlternateScreen()
            keyReader.disableRawMode()
        }

        // Load initial data
        await loadConversations()

        // Main loop with timeout-based polling for message updates
        while isRunning {
            render()

            // Check for pending message updates before blocking on key read
            if let newMessages = pendingMessages {
                pendingMessages = nil
                messages = newMessages
                messageScrollOffset = max(0, messages.count - getMessageAreaHeight())
                continue // Re-render immediately
            }

            // Use a short timeout so we can check for message updates
            let key = await keyReader.readKeyAsyncWithTimeout(milliseconds: 100)
            if let key = key {
                await handleKey(key)
            }
        }
    }

    // MARK: - Data Loading

    private func loadConversations() async {
        statusMessage = "Loading conversations..."
        render()

        do {
            let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
            conversations = try repo.fetchAll()
            statusMessage = ""
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func loadMessages(for conversationId: String) async {
        statusMessage = "Loading messages..."
        render()

        do {
            let repo = context.session.messagesRepository(for: conversationId)
            messages = try repo.fetchInitial()
            messageScrollOffset = max(0, messages.count - getMessageAreaHeight())
            statusMessage = ""

            // Subscribe to message updates for live streaming
            subscribeToMessages(repo: repo)
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func subscribeToMessages(repo: any MessagesRepositoryProtocol) {
        // Cancel any existing subscription
        messageSubscription?.cancel()

        // Subscribe to message updates
        messageSubscription = repo.messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMessages in
                // Store pending messages to be picked up by the run loop
                self?.pendingMessages = newMessages
            }
    }

    private func unsubscribeFromMessages() {
        messageSubscription?.cancel()
        messageSubscription = nil
        pendingMessages = nil
    }

    // MARK: - Rendering (Double-buffered for flicker-free updates)

    private func render() {
        let buf = ScreenBuffer()
        buf.clear()

        switch currentScreen {
        case .conversationList:
            renderConversationList(to: buf)
        case let .chat(id, name):
            renderChat(to: buf, conversationId: id, name: name)
        case .joinPrompt:
            renderJoinPrompt(to: buf)
        case .createPrompt:
            renderCreatePrompt(to: buf)
        case let .inviteQR(_, name, inviteSlug):
            renderInviteQR(to: buf, name: name, inviteSlug: inviteSlug)
        case let .deleteConfirm(_, name, _, _):
            renderDeleteConfirm(to: buf, name: name)
        }

        buf.render()
    }

    private func renderConversationList(to buf: ScreenBuffer) {
        let rows = buf.rows

        // Header
        buf.write(row: 1, col: 1, Terminal.bold("Convos CLI"))
        buf.write(row: 2, col: 1, Terminal.dim("↑/↓ navigate  Enter open  n new  j join  d delete  r refresh  q quit"))
        buf.writeLine(row: 3)

        // Conversations
        if conversations.isEmpty {
            buf.write(row: 5, col: 1, Terminal.dim("No conversations yet. Press 'n' to create one or 'j' to join."))
        } else {
            let startRow = 4
            let maxVisible = rows - 6 // Leave room for header and footer

            for (index, conv) in conversations.enumerated() {
                if index >= maxVisible { break }

                let row = startRow + index
                let isSelected = index == selectedIndex

                let unreadMarker = conv.isUnread ? Terminal.brightCyan("●") : " "
                let memberCount = Terminal.dim("(\(conv.members.count))")
                let line = "\(unreadMarker) \(conv.displayName) \(memberCount)"

                let displayLine = isSelected ? Terminal.inverse(" \(line) ") : " \(line) "
                buf.write(row: row, col: 1, displayLine)
            }
        }

        // Footer
        buf.writeLine(row: rows - 1)
        if !statusMessage.isEmpty {
            buf.write(row: rows, col: 1, Terminal.yellow(statusMessage))
        } else {
            buf.write(row: rows, col: 1, Terminal.dim("\(conversations.count) conversations"))
        }

        buf.hideCursor()
    }

    private func renderChat(to buf: ScreenBuffer, conversationId: String, name: String) {
        let rows = buf.rows
        let cols = buf.cols

        // Header
        buf.write(row: 1, col: 1, Terminal.bold(name))
        buf.write(row: 2, col: 1, Terminal.dim("Esc back  ↑/↓ scroll  Tab invite QR  Type to compose  Enter send"))
        buf.writeLine(row: 3)

        // Messages
        let messageAreaStart = 4
        let messageAreaHeight = rows - 6 // Header (3) + input (2) + status (1)

        if messages.isEmpty {
            buf.write(row: messageAreaStart, col: 1, Terminal.dim("No messages yet. Type something to start the conversation."))
        } else {
            let visibleMessages = Array(messages.dropFirst(messageScrollOffset).prefix(messageAreaHeight))

            for (index, message) in visibleMessages.enumerated() {
                let row = messageAreaStart + index
                renderMessage(to: buf, message: message, at: row, cols: cols)
            }
        }

        // Input area
        let inputRow = rows - 2
        buf.writeLine(row: inputRow)
        buf.write(row: rows - 1, col: 1, "> \(lineEditor.text)")

        // Status
        if !statusMessage.isEmpty {
            buf.write(row: rows, col: 1, Terminal.yellow(statusMessage))
        }

        // Position cursor in input field
        buf.setCursor(row: rows - 1, col: 3 + lineEditor.cursorPosition)
    }

    private func renderMessage(to buf: ScreenBuffer, message: AnyMessage, at row: Int, cols: Int) {
        let base = message.base
        let sender = base.sender.profile.displayName
        let time = formatTime(base.date)
        let content = formatMessageContent(message)

        let header = Terminal.cyan(sender) + " " + Terminal.dim(time)
        buf.write(row: row, col: 1, "\(header): \(content)")
    }

    private func renderJoinPrompt(to buf: ScreenBuffer) {
        let rows = buf.rows

        buf.write(row: 1, col: 1, Terminal.bold("Join Conversation"))
        buf.writeLine(row: 2)
        buf.write(row: 4, col: 1, "Enter invite URL or slug:")
        buf.write(row: 5, col: 1, "> \(lineEditor.text)")
        buf.write(row: 7, col: 1, Terminal.dim("Press Enter to join, Esc to cancel"))

        if !statusMessage.isEmpty {
            buf.write(row: rows, col: 1, Terminal.yellow(statusMessage))
        }

        buf.setCursor(row: 5, col: 3 + lineEditor.cursorPosition)
    }

    private func renderCreatePrompt(to buf: ScreenBuffer) {
        let rows = buf.rows

        buf.write(row: 1, col: 1, Terminal.bold("Create Conversation"))
        buf.writeLine(row: 2)
        buf.write(row: 4, col: 1, "Enter conversation name (optional):")
        buf.write(row: 5, col: 1, "> \(lineEditor.text)")
        buf.write(row: 7, col: 1, Terminal.dim("Press Enter to create, Esc to cancel"))

        if !statusMessage.isEmpty {
            buf.write(row: rows, col: 1, Terminal.yellow(statusMessage))
        }

        buf.setCursor(row: 5, col: 3 + lineEditor.cursorPosition)
    }

    private func renderInviteQR(to buf: ScreenBuffer, name: String, inviteSlug: String) {
        let rows = buf.rows
        let cols = buf.cols

        // Header
        buf.write(row: 1, col: 1, Terminal.bold("Invite to: \(name)"))
        buf.write(row: 2, col: 1, Terminal.dim("Esc back  c copy invite"))
        buf.writeLine(row: 3)

        // Build the invite URL using the environment's domain
        let inviteURL = "https://\(context.environment.inviteDomain)/v2?i=\(inviteSlug)"

        // Generate QR code
        let qrLines = QRCode.render(from: inviteURL, label: nil)

        // Calculate centering
        let qrHeight = qrLines.count
        let startRow = max(4, (rows - qrHeight) / 2)

        // Render QR code centered
        for (index, line) in qrLines.enumerated() {
            let lineWidth = line.count
            let startCol = max(1, (cols - lineWidth) / 2)
            buf.write(row: startRow + index, col: startCol, line)
        }

        // Footer
        buf.writeLine(row: rows - 1)
        if !statusMessage.isEmpty {
            buf.write(row: rows, col: 1, Terminal.yellow(statusMessage))
        }

        buf.hideCursor()
    }

    private func renderDeleteConfirm(to buf: ScreenBuffer, name: String) {
        let rows = buf.rows

        buf.write(row: 1, col: 1, Terminal.bold(Terminal.red("Delete Conversation")))
        buf.writeLine(row: 2)
        buf.write(row: 4, col: 1, "Are you sure you want to delete:")
        buf.write(row: 5, col: 1, Terminal.bold("  \(name)"))
        buf.write(row: 7, col: 1, Terminal.yellow("This will delete the inbox and all local data."))
        buf.write(row: 8, col: 1, Terminal.yellow("This action cannot be undone."))
        buf.write(row: 10, col: 1, "Press " + Terminal.bold("y") + " to confirm, " + Terminal.bold("n") + " or Esc to cancel")

        if !statusMessage.isEmpty {
            buf.write(row: rows, col: 1, Terminal.yellow(statusMessage))
        }

        buf.hideCursor()
    }

    // MARK: - Input Handling

    private func handleKey(_ key: Key) async {
        switch currentScreen {
        case .conversationList:
            await handleConversationListKey(key)
        case let .chat(id, name):
            await handleChatKey(key, conversationId: id, name: name)
        case .joinPrompt:
            await handleJoinPromptKey(key)
        case .createPrompt:
            await handleCreatePromptKey(key)
        case let .inviteQR(id, name, inviteSlug):
            await handleInviteQRKey(key, conversationId: id, name: name, inviteSlug: inviteSlug)
        case let .deleteConfirm(id, name, clientId, inboxId):
            await handleDeleteConfirmKey(key, conversationId: id, name: name, clientId: clientId, inboxId: inboxId)
        }
    }

    private func handleConversationListKey(_ key: Key) async {
        switch key {
        case .char("q"), .char("Q"):
            isRunning = false

        case .up:
            if selectedIndex > 0 {
                selectedIndex -= 1
            }

        case .down:
            if selectedIndex < conversations.count - 1 {
                selectedIndex += 1
            }

        case .enter:
            if !conversations.isEmpty && selectedIndex < conversations.count {
                let conv = conversations[selectedIndex]
                currentScreen = .chat(conversationId: conv.id, name: conv.displayName)
                await loadMessages(for: conv.id)
                Terminal.hideCursor()
            }

        case .char("n"), .char("N"):
            currentScreen = .createPrompt
            lineEditor.clear()

        case .char("j"), .char("J"):
            currentScreen = .joinPrompt
            lineEditor.clear()

        case .char("r"), .char("R"):
            await loadConversations()

        case .char("d"), .char("D"):
            if !conversations.isEmpty && selectedIndex < conversations.count {
                let conv = conversations[selectedIndex]
                currentScreen = .deleteConfirm(conversationId: conv.id, name: conv.displayName, clientId: conv.clientId, inboxId: conv.inboxId)
            }

        default:
            break
        }
    }

    private func handleChatKey(_ key: Key, conversationId: String, name: String) async {
        switch key {
        case .escape:
            unsubscribeFromMessages()
            currentScreen = .conversationList
            messages = []
            messageScrollOffset = 0
            lineEditor.clear()
            Terminal.hideCursor()
            await loadConversations()

        case .up:
            if messageScrollOffset > 0 {
                messageScrollOffset -= 1
            }

        case .down:
            let maxOffset = max(0, messages.count - getMessageAreaHeight())
            if messageScrollOffset < maxOffset {
                messageScrollOffset += 1
            }

        case .enter:
            let text = lineEditor.getText()
            if !text.isEmpty {
                await sendMessage(text, to: conversationId)
            }

        case .tab:
            // Show invite QR code (Tab / Ctrl+I)
            await showInviteQR(conversationId: conversationId, name: name)

        default:
            _ = lineEditor.handleKey(key)
        }
    }

    private func handleJoinPromptKey(_ key: Key) async {
        switch key {
        case .escape:
            currentScreen = .conversationList
            lineEditor.clear()
            statusMessage = ""
            Terminal.hideCursor()

        case .enter:
            let invite = lineEditor.getText()
            if !invite.isEmpty {
                await joinConversation(invite: invite)
            }

        default:
            _ = lineEditor.handleKey(key)
        }
    }

    private func handleCreatePromptKey(_ key: Key) async {
        switch key {
        case .escape:
            currentScreen = .conversationList
            lineEditor.clear()
            statusMessage = ""
            Terminal.hideCursor()

        case .enter:
            let name = lineEditor.getText()
            await createConversation(name: name.isEmpty ? nil : name)

        default:
            _ = lineEditor.handleKey(key)
        }
    }

    private func handleInviteQRKey(_ key: Key, conversationId: String, name: String, inviteSlug: String) async {
        switch key {
        case .escape:
            // Go back to chat
            currentScreen = .chat(conversationId: conversationId, name: name)
            statusMessage = ""

        case .char("c"), .char("C"):
            // Copy full invite URL to clipboard using pbcopy
            let inviteURL = "https://\(context.environment.inviteDomain)/v2?i=\(inviteSlug)"
            copyToClipboard(inviteURL)
            statusMessage = "Copied invite URL to clipboard!"

        default:
            break
        }
    }

    private func handleDeleteConfirmKey(_ key: Key, conversationId: String, name: String, clientId: String, inboxId: String) async {
        switch key {
        case .escape, .char("n"), .char("N"):
            // Cancel deletion
            currentScreen = .conversationList
            statusMessage = ""

        case .char("y"), .char("Y"):
            // Confirm deletion
            await deleteInbox(clientId: clientId, inboxId: inboxId, name: name)

        default:
            break
        }
    }

    // MARK: - Actions

    private func showInviteQR(conversationId: String, name: String) async {
        statusMessage = "Loading invite..."
        render()

        do {
            // Find conversation for clientId/inboxId
            guard let conv = conversations.first(where: { $0.id == conversationId }) else {
                statusMessage = "Error: Conversation not found"
                return
            }

            // Wake the messaging service to ensure invite is available
            _ = try await context.session.messagingService(
                for: conv.clientId,
                inboxId: conv.inboxId
            )

            // Get invite from session's invite repository
            let inviteRepo = context.session.inviteRepository(for: conversationId)
            let inviteSlug = try await waitForInvite(inviteRepo: inviteRepo)

            statusMessage = ""
            currentScreen = .inviteQR(conversationId: conversationId, name: name, inviteSlug: inviteSlug)
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func waitForInvite(inviteRepo: any InviteRepositoryProtocol) async throws -> String {
        // Wait for invite to be published
        return try await withCheckedThrowingContinuation { continuation in
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

    private func copyToClipboard(_ string: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")

        let pipe = Pipe()
        process.standardInput = pipe

        do {
            try process.run()
            pipe.fileHandleForWriting.write(Data(string.utf8))
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            statusMessage = "Failed to copy: \(error.localizedDescription)"
        }
    }

    private func sendMessage(_ text: String, to conversationId: String) async {
        statusMessage = "Sending..."
        render()

        do {
            // Find conversation for clientId/inboxId
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
            // Messages will be updated via the subscription
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func joinConversation(invite: String) async {
        statusMessage = "Joining..."
        render()

        do {
            // Extract slug from URL if needed
            let inviteSlug = extractInviteSlug(from: invite)

            // Create a new inbox for joining
            let messagingService = await context.session.addInbox()
            _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()

            let stateManager = messagingService.conversationStateManager()
            try await stateManager.joinConversation(inviteCode: inviteSlug)

            statusMessage = "Join request sent! Waiting for acceptance..."

            // Go back to list and refresh
            currentScreen = .conversationList
            Terminal.hideCursor()
            await loadConversations()
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func deleteInbox(clientId: String, inboxId: String, name: String) async {
        statusMessage = "Deleting..."
        render()

        do {
            try await context.session.deleteInbox(clientId: clientId, inboxId: inboxId)
            statusMessage = "Deleted '\(name)'"
            currentScreen = .conversationList

            // Adjust selected index if needed
            if selectedIndex >= conversations.count - 1 && selectedIndex > 0 {
                selectedIndex -= 1
            }

            await loadConversations()
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            currentScreen = .conversationList
        }
    }

    private func createConversation(name: String?) async {
        statusMessage = "Creating..."
        render()

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
                    if let name = name {
                        try await stateManager.conversationMetadataWriter.updateName(name, for: result.conversationId)
                    }
                    statusMessage = "Created! ID: \(result.conversationId)"
                    currentScreen = .conversationList
                    Terminal.hideCursor()
                    await loadConversations()
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

    // MARK: - Helpers

    private func getMessageAreaHeight() -> Int {
        let (rows, _) = Terminal.getSize()
        return rows - 6 // Header (3) + input (2) + status (1)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatMessageContent(_ message: AnyMessage) -> String {
        switch message.base.content {
        case .text(let text):
            return text
        case .emoji(let emoji):
            return emoji
        case .invite:
            return "[Invite]"
        case .attachment:
            return "[Attachment]"
        case .attachments(let urls):
            return "[Attachments: \(urls.count)]"
        case .update:
            return "[Group updated]"
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
