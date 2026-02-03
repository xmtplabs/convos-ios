import ArgumentParser
import ConvosCore
import Foundation

struct Send: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to a conversation"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Conversation ID")
    var conversationId: String

    @Argument(help: "Message text")
    var message: String

    @Option(name: .long, help: "Reply to message ID")
    var replyTo: String?

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Get the inbox ID for this conversation
        guard let inboxId = await context.session.inboxId(for: conversationId) else {
            throw CLIError.conversationNotFound(conversationId)
        }

        // Look up the conversation to get clientId
        let repo = context.session.conversationsRepository(for: .all)
        let conversations = try repo.fetchAll()
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw CLIError.conversationNotFound(conversationId)
        }

        // Get messaging service for this inbox
        let messagingService = try await context.session.messagingService(
            for: conversation.clientId,
            inboxId: inboxId
        )

        // Send the message
        let messageWriter = messagingService.messageWriter(for: conversationId)
        try await messageWriter.send(text: message)

        switch options.output {
        case .text:
            print("Message sent to \(conversation.displayName)")
        case .json:
            let output = SendOutput(
                success: true,
                conversationId: conversationId,
                message: message
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(output)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        }
    }
}

struct SendOutput: Codable {
    let success: Bool
    let conversationId: String
    let message: String
}
