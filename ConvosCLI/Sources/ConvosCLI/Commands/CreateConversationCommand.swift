import ArgumentParser
import Combine
import ConvosCore
import Foundation

struct CreateConversation: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "create-conversation",
        abstract: "Create a new conversation and output an invite slug"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "Name for the conversation")
    var name: String?

    @Option(name: .long, help: "Description for the conversation")
    var description: String?

    @Option(name: .long, help: "Timeout in seconds (default: 30)")
    var timeout: Int = 30

    mutating func run() async throws {
        let verbose = options.verbose

        if verbose {
            CreateConversation.log("[verbose] Starting create-conversation command...")
        }

        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: verbose
        )

        if verbose {
            CreateConversation.log("[verbose] CLIContext initialized")
        }

        // Create a new inbox for this conversation
        if verbose {
            CreateConversation.log("[verbose] Creating new inbox...")
        }
        let messagingService = await context.session.addInbox()
        if verbose {
            CreateConversation.log("[verbose] Inbox created")
        }

        // Get the conversation state manager for creating a new conversation
        // createConversation() internally waits for inbox ready via waitForInboxReadyResult()
        let stateManager = messagingService.conversationStateManager()
        if verbose {
            CreateConversation.log("[verbose] Initial conversation state: \(stateManager.currentState)")
        }

        // Wait for the conversation to be created
        if verbose {
            CreateConversation.log("[verbose] Waiting for conversation to be ready (timeout: \(timeout)s)...")
        }
        let result = try await withTimeout(seconds: timeout) {
            try await CreateConversation.waitForReady(stateManager: stateManager, verbose: verbose)
        }

        // Update conversation metadata if provided
        if let name = name {
            try await stateManager.conversationMetadataWriter.updateName(name, for: result.conversationId)
        }
        if let description = description {
            try await stateManager.conversationMetadataWriter.updateDescription(description, for: result.conversationId)
        }

        // Get the invite for this conversation
        let inviteRepo = context.session.inviteRepository(for: result.conversationId)
        let inviteSlug = try await CreateConversation.waitForInvite(inviteRepo: inviteRepo)

        switch options.output {
        case .text:
            print("Created new conversation")
            print("Conversation ID: \(result.conversationId)")
            if let name = name {
                print("Name: \(name)")
            }
            print("Invite slug: \(inviteSlug)")

        case .json:
            let output = CreateConversationOutput(
                success: true,
                conversationId: result.conversationId,
                inviteSlug: inviteSlug,
                name: name,
                description: description
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(output)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func waitForReady(stateManager: any ConversationStateManagerProtocol, verbose: Bool) async throws -> ConversationReadyResult {
        // Trigger conversation creation
        if verbose {
            log("[verbose] Calling createConversation()...")
        }
        try await stateManager.createConversation()
        if verbose {
            log("[verbose] createConversation() returned, now polling for ready state...")
        }

        var lastLoggedState: String?

        // Poll for state changes since CLI doesn't have a RunLoop for MainActor callbacks
        while true {
            try Task.checkCancellation()

            let state = stateManager.currentState
            let stateDescription = "\(state)"

            if verbose && stateDescription != lastLoggedState {
                log("[verbose] State: \(stateDescription)")
                lastLoggedState = stateDescription
            }

            switch state {
            case .ready(let result):
                if verbose {
                    log("[verbose] Reached ready state!")
                }
                return result

            case .error(let error):
                if verbose {
                    log("[verbose] Error state: \(error)")
                }
                throw error

            default:
                // Wait a bit before checking again
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private static func waitForInvite(inviteRepo: any InviteRepositoryProtocol) async throws -> String {
        // Get the invite from the repository publisher
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

    private func withTimeout<T: Sendable>(seconds: Int, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw CLIError.timeout(seconds: seconds)
            }

            guard let result = try await group.next() else {
                throw CLIError.timeout(seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}

struct CreateConversationOutput: Codable {
    let success: Bool
    let conversationId: String
    let inviteSlug: String
    let name: String?
    let description: String?
}
