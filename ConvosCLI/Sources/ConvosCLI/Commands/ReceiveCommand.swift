import ArgumentParser
import ConvosCore
import Foundation

struct Receive: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "receive",
        abstract: "Receive and display new messages"
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Keep running and stream messages as they arrive")
    var stream: Bool = false

    @Option(name: .shortAndLong, help: "Timeout in seconds (for non-streaming mode)")
    var timeout: Int = 5

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Initialize inbox and wait for sync to complete
        // This ensures we have the latest messages from the network
        let messagingService = await context.session.addInbox()
        _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()

        // Give the syncing manager a moment to process messages after becoming ready
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        if stream {
            // Stream mode - continuously print messages using MessageStreamProvider
            print("Streaming messages... (Ctrl+C to stop)")

            let streamProvider = messagingService.messageStreamProvider()
            for try await message in streamProvider.stream(consentStates: [.allowed, .unknown]) {
                // Look up the conversation for this message
                let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
                if let conversation = try? repo.fetchAll().first(where: { $0.id == message.conversationId }) {
                    outputStreamedMessage(message, conversationName: conversation.displayName)
                } else {
                    // Fallback if conversation not found
                    outputStreamedMessage(message, conversationName: message.conversationId)
                }
            }
        } else {
            // One-shot mode - fetch recent messages
            print("Fetching messages...")

            // Get all allowed conversations
            let repo = context.session.conversationsRepository(for: [.allowed, .unknown])
            let conversations = try repo.fetchAll()

            var totalMessages = 0
            for conversation in conversations {
                let messagesRepo = context.session.messagesRepository(for: conversation.id)
                let messages = try messagesRepo.fetchInitial()

                for message in messages.prefix(10) {
                    outputMessage(message, conversation: conversation)
                    totalMessages += 1
                }
            }

            print("\nTotal: \(totalMessages) messages from \(conversations.count) conversations")
        }
    }

    // MARK: - Output for AnyMessage (database queries)

    private func outputMessage(_ message: AnyMessage, conversation: Conversation) {
        let base = message.base
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        let date = dateFormatter.string(from: base.date)

        switch options.output {
        case .text:
            let sender = base.sender.profile.displayName
            let preview = messagePreview(message)
            print("[\(date)] [\(conversation.displayName)] \(sender): \(preview)")

        case .json:
            let output = ReceivedMessageOutput(
                channel: "convos",
                conversationId: conversation.id,
                conversationName: conversation.displayName,
                messageId: message.id,
                senderName: base.sender.profile.displayName,
                senderId: base.sender.profile.id,
                content: messagePreview(message),
                timestamp: base.date
            )
            if let json = try? JSONEncoder().encode(output),
               let str = String(data: json, encoding: .utf8) {
                print(str)
            }
        }
    }

    private func messagePreview(_ message: AnyMessage) -> String {
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

    // MARK: - Output for StreamedMessage (live streaming)

    private func outputStreamedMessage(_ message: StreamedMessage, conversationName: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        let date = dateFormatter.string(from: message.sentAt)

        switch options.output {
        case .text:
            let preview = streamedMessagePreview(message)
            print("[\(date)] [\(conversationName)] \(message.senderInboxId): \(preview)")

        case .json:
            let output = ReceivedMessageOutput(
                channel: "convos",
                conversationId: message.conversationId,
                conversationName: conversationName,
                messageId: message.id,
                senderName: message.senderInboxId,
                senderId: message.senderInboxId,
                content: streamedMessagePreview(message),
                timestamp: message.sentAt
            )
            if let json = try? JSONEncoder().encode(output),
               let str = String(data: json, encoding: .utf8) {
                print(str)
            }
        }
    }

    private func streamedMessagePreview(_ message: StreamedMessage) -> String {
        switch message.content {
        case .text(let text):
            return text
        case .emoji(let emoji):
            return emoji
        case let .reaction(emoji, _, action):
            let actionStr = action == .added ? "added" : "removed"
            return "[Reaction \(actionStr): \(emoji)]"
        case .attachment:
            return "[Attachment]"
        case .attachments(let urls):
            return "[Attachments: \(urls.count)]"
        case .groupUpdate:
            return "[Group updated]"
        case .unsupported:
            return "[Unsupported message type]"
        }
    }
}

struct ReceivedMessageOutput: Codable {
    let channel: String
    let conversationId: String
    let conversationName: String
    let messageId: String
    let senderName: String
    let senderId: String
    let content: String
    let timestamp: Date
}
