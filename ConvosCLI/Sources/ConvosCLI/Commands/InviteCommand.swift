import ArgumentParser
import Combine
import ConvosCore
import Foundation

struct Invite: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "invite",
        abstract: "Generate an invite slug for an existing conversation"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Conversation ID")
    var conversationId: String

    @Option(name: .long, help: "Timeout in seconds (default: 10)")
    var timeout: Int = 10

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Look up the conversation
        let conversationsRepo = context.session.conversationsRepository(for: .all)
        let conversations = try conversationsRepo.fetchAll()
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw CLIError.conversationNotFound(conversationId)
        }

        // Get the invite repository for this conversation
        let inviteRepo = context.session.inviteRepository(for: conversationId)

        // Wait for the invite to be available with timeout
        let inviteSlug = try await waitForInviteWithTimeout(inviteRepo: inviteRepo, timeout: timeout, conversationId: conversationId)

        switch options.output {
        case .text:
            print("Invite for: \(conversation.displayName)")
            print("Conversation ID: \(conversationId)")
            print("Invite slug: \(inviteSlug)")

        case .json:
            let output = InviteOutput(
                conversationId: conversationId,
                conversationName: conversation.displayName,
                inviteSlug: inviteSlug
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(output)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        }
    }

    private func waitForInviteWithTimeout(inviteRepo: any InviteRepositoryProtocol, timeout: Int, conversationId: String) async throws -> String {
        // Use Combine's timeout operator
        return try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var resumed = false

            cancellable = inviteRepo.invitePublisher
                .compactMap { $0 }
                .timeout(.seconds(timeout), scheduler: DispatchQueue.main)
                .first()
                .sink(
                    receiveCompletion: { completion in
                        guard !resumed else { return }
                        resumed = true
                        if case .failure = completion {
                            continuation.resume(throwing: CLIError.inviteNotFound(conversationId: conversationId))
                        }
                        // Note: .finished without value means timeout
                    },
                    receiveValue: { invite in
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: invite.urlSlug)
                        cancellable?.cancel()
                    }
                )
        }
    }
}

struct InviteOutput: Codable {
    let conversationId: String
    let conversationName: String
    let inviteSlug: String
}
