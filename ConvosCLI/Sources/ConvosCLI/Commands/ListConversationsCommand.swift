import ArgumentParser
import ConvosCore
import Foundation

struct ListConversations: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "list-conversations",
        abstract: "List all conversations"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "Maximum number of conversations to show")
    var limit: Int?

    @Flag(name: .long, help: "Include hidden/denied conversations")
    var includeHidden: Bool = false

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Get conversation repository with appropriate consent filter
        let consent: [Consent] = includeHidden ? .all : [.allowed, .unknown]
        let repo = context.session.conversationsRepository(for: consent)

        // Fetch all conversations
        var conversations = try repo.fetchAll()

        // Apply limit if specified
        if let limit = limit {
            conversations = Array(conversations.prefix(limit))
        }

        // Output based on format
        switch options.output {
        case .text:
            outputText(conversations)
        case .json:
            try outputJSON(conversations)
        }
    }

    private func outputText(_ conversations: [Conversation]) {
        if conversations.isEmpty {
            print("No conversations found.")
            return
        }

        for conv in conversations {
            let unreadIndicator = conv.isUnread ? " (unread)" : ""
            let pinnedIndicator = conv.isPinned ? " [pinned]" : ""
            let mutedIndicator = conv.isMuted ? " [muted]" : ""
            let memberCount = conv.members.count

            print("\(conv.id)\t\(conv.displayName) (\(memberCount) members)\(unreadIndicator)\(pinnedIndicator)\(mutedIndicator)")
        }
    }

    private func outputJSON(_ conversations: [Conversation]) throws {
        let output = conversations.map { conv in
            ConversationOutput(
                id: conv.id,
                displayName: conv.displayName,
                memberCount: conv.members.count,
                isUnread: conv.isUnread,
                isPinned: conv.isPinned,
                isMuted: conv.isMuted,
                kind: conv.kind.rawValue,
                createdAt: conv.createdAt,
                lastMessagePreview: conv.lastMessage?.text
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
}

// MARK: - Output Models

struct ConversationOutput: Codable {
    let id: String
    let displayName: String
    let memberCount: Int
    let isUnread: Bool
    let isPinned: Bool
    let isMuted: Bool
    let kind: String
    let createdAt: Date
    let lastMessagePreview: String?
}
