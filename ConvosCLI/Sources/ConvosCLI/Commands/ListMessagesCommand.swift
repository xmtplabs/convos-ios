import ArgumentParser
import ConvosCore
import Foundation

struct ListMessages: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "list-messages",
        abstract: "List messages in a conversation"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Conversation ID")
    var conversationId: String

    @Option(name: .shortAndLong, help: "Maximum number of messages to show")
    var limit: Int = 50

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Get messages repository for this conversation
        let repo = context.session.messagesRepository(for: conversationId)

        // Fetch messages
        let messages = try repo.fetchInitial()

        // Apply limit
        let limitedMessages = Array(messages.prefix(limit))

        // Output based on format
        switch options.output {
        case .text:
            outputText(limitedMessages)
        case .json:
            try outputJSON(limitedMessages)
        }
    }

    private func outputText(_ messages: [AnyMessage]) {
        if messages.isEmpty {
            print("No messages found.")
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        for message in messages {
            let base = message.base
            let date = dateFormatter.string(from: base.date)
            let sender = base.sender.profile.displayName
            let preview = messagePreview(message)
            print("[\(date)] \(sender): \(preview)")
            if options.verbose {
                print("  ID: \(message.id)")
            }
        }
    }

    private func outputJSON(_ messages: [AnyMessage]) throws {
        let output = messages.map { msg in
            let base = msg.base
            return MessageOutput(
                id: msg.id,
                conversationId: conversationId,
                senderName: base.sender.profile.displayName,
                senderId: base.sender.profile.id,
                content: messagePreview(msg),
                date: base.date,
                status: String(describing: base.status)
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(output)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
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
}

// MARK: - Output Models

struct MessageOutput: Codable {
    let id: String
    let conversationId: String
    let senderName: String
    let senderId: String
    let content: String
    let date: Date
    let status: String
}
