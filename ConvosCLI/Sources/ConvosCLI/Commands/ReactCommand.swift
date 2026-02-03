import ArgumentParser
import ConvosCore
import Foundation

struct React: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "react",
        abstract: "Add or remove a reaction to a message"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Conversation ID")
    var conversationId: String

    @Argument(help: "Message ID to react to")
    var messageId: String

    @Argument(help: "Emoji reaction")
    var emoji: String

    @Flag(name: .long, help: "Remove the reaction instead of adding")
    var remove: Bool = false

    @Flag(name: .long, help: "Toggle the reaction (add if not present, remove if present)")
    var toggle: Bool = false

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Look up the conversation to get clientId/inboxId
        let repo = context.session.conversationsRepository(for: .all)
        let conversations = try repo.fetchAll()
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw CLIError.conversationNotFound(conversationId)
        }

        // Get messaging service for this inbox
        let messagingService = try await context.session.messagingService(
            for: conversation.clientId,
            inboxId: conversation.inboxId
        )

        // Get reaction writer
        let reactionWriter = messagingService.reactionWriter()

        // Perform the action
        if toggle {
            try await reactionWriter.toggleReaction(emoji: emoji, to: messageId, in: conversationId)
        } else if remove {
            try await reactionWriter.removeReaction(emoji: emoji, from: messageId, in: conversationId)
        } else {
            try await reactionWriter.addReaction(emoji: emoji, to: messageId, in: conversationId)
        }

        // Output
        let action = toggle ? "toggled" : (remove ? "removed" : "added")

        switch options.output {
        case .text:
            print("Reaction \(emoji) \(action) on message \(messageId)")

        case .json:
            let output = ReactOutput(
                success: true,
                action: action,
                emoji: emoji,
                messageId: messageId,
                conversationId: conversationId
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

struct ReactOutput: Codable {
    let success: Bool
    let action: String
    let emoji: String
    let messageId: String
    let conversationId: String
}
