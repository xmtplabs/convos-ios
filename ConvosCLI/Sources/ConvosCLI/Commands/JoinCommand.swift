import ArgumentParser
import ConvosCore
import Foundation

struct Join: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "join",
        abstract: "Join a conversation using an invite slug or URL"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Invite slug or full invite URL (e.g., https://dev.convos.org/v2?i=...)")
    var invite: String

    /// Extract the invite slug from input (URL or raw slug)
    private var inviteSlug: String {
        // Check if it's a URL with i= parameter
        if let url = URL(string: invite),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let slugItem = queryItems.first(where: { $0.name == "i" }),
           let slug = slugItem.value {
            return slug
        }
        // Otherwise treat as raw slug
        return invite
    }

    @Option(name: .long, help: "Timeout in seconds for join request (default: 60)")
    var timeout: Int = 60

    @Flag(name: .long, help: "Don't wait for the creator to accept; return after validation")
    var noWait: Bool = false

    mutating func run() async throws {
        let verbose = options.verbose

        if verbose {
            Join.log("[verbose] Starting join command...")
        }

        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: verbose
        )

        if verbose {
            Join.log("[verbose] CLIContext initialized")
        }

        let extractedSlug = inviteSlug
        if verbose {
            Join.log("[verbose] Input invite: \(invite)")
            Join.log("[verbose] Extracted slug: \(extractedSlug)")
        }

        // Create a new inbox for joining this conversation
        if verbose {
            Join.log("[verbose] Creating new inbox...")
        }
        let messagingService = await context.session.addInbox()
        if verbose {
            Join.log("[verbose] Inbox created")
        }

        // Get the conversation state manager
        // Note: joinConversation() internally waits for inbox ready via waitForInboxReadyResult()
        let stateManager = messagingService.conversationStateManager()
        if verbose {
            Join.log("[verbose] Initial conversation state: \(stateManager.currentState)")
        }

        if noWait {
            // Just validate and send the join request
            let validatedState = try await waitForValidated(stateManager: stateManager, verbose: verbose)

            switch options.output {
            case .text:
                print("Join request sent")
                print("Placeholder ID: \(validatedState.placeholderConversationId)")
                if let name = validatedState.inviteName {
                    print("Conversation name: \(name)")
                }
                print("Status: waiting_for_acceptance")
                print("Note: The conversation creator must accept your join request")

            case .json:
                let output = JoinOutput(
                    success: true,
                    status: "waiting_for_acceptance",
                    conversationId: validatedState.placeholderConversationId,
                    conversationName: validatedState.inviteName
                )
                try outputJSON(output)
            }
        } else {
            // Wait for full acceptance
            if verbose {
                Join.log("[verbose] Waiting for full acceptance (timeout: \(timeout)s)...")
            }
            let result = try await withTimeout(seconds: timeout) {
                try await Join.waitForReady(stateManager: stateManager, inviteCode: extractedSlug, verbose: verbose)
            }

            switch options.output {
            case .text:
                print("Successfully joined conversation")
                print("Conversation ID: \(result.conversationId)")

            case .json:
                let output = JoinOutput(
                    success: true,
                    status: "joined",
                    conversationId: result.conversationId,
                    conversationName: nil
                )
                try outputJSON(output)
            }
        }
    }

    private struct ValidatedState: Sendable {
        let inviteName: String?
        let placeholderConversationId: String
    }

    private func waitForValidated(stateManager: any ConversationStateManagerProtocol, verbose: Bool) async throws -> ValidatedState {
        try await Join.waitForValidated(stateManager: stateManager, inviteCode: inviteSlug, verbose: verbose)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func waitForValidated(stateManager: any ConversationStateManagerProtocol, inviteCode: String, verbose: Bool) async throws -> ValidatedState {
        // Start the join flow first
        if verbose {
            log("[verbose] Calling joinConversation(inviteCode: \(inviteCode))...")
        }
        try await stateManager.joinConversation(inviteCode: inviteCode)
        if verbose {
            log("[verbose] joinConversation() returned, now polling for state changes...")
        }

        var lastLoggedState: String?

        // Poll for state changes since observer callbacks require MainActor which may be blocked
        while true {
            try Task.checkCancellation()

            let state = stateManager.currentState
            let stateDescription = "\(state)"

            if verbose && stateDescription != lastLoggedState {
                log("[verbose] State changed to: \(stateDescription)")
                lastLoggedState = stateDescription
            }

            switch state {
            case let .validated(invite, placeholder, _, _):
                if verbose {
                    log("[verbose] Reached validated state!")
                }
                return ValidatedState(
                    inviteName: invite.name,
                    placeholderConversationId: placeholder.conversationId
                )

            case .joinFailed(_, let error):
                if verbose {
                    log("[verbose] Join failed: \(error.userFacingMessage)")
                }
                throw CLIError.joinFailed(error.userFacingMessage)

            case .error(let error):
                if verbose {
                    log("[verbose] Error state: \(error)")
                }
                throw error

            case .ready(let result):
                // Already ready (existing conversation)
                if verbose {
                    log("[verbose] Already ready!")
                }
                return ValidatedState(
                    inviteName: nil,
                    placeholderConversationId: result.conversationId
                )

            default:
                // Still waiting - poll every 100ms
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func waitForReady(stateManager: any ConversationStateManagerProtocol, inviteCode: String, verbose: Bool) async throws -> ConversationReadyResult {
        // Start the join flow first
        if verbose {
            log("[verbose] Calling joinConversation(inviteCode: \(inviteCode))...")
        }
        try await stateManager.joinConversation(inviteCode: inviteCode)
        if verbose {
            log("[verbose] joinConversation() returned, now polling for ready state...")
        }

        var lastLoggedState: String?

        // Poll for state changes since observer callbacks require MainActor which may be blocked
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

            case .joinFailed(_, let error):
                if verbose {
                    log("[verbose] Join failed: \(error.userFacingMessage)")
                }
                throw CLIError.joinFailed(error.userFacingMessage)

            case .error(let error):
                if verbose {
                    log("[verbose] Error state: \(error)")
                }
                throw error

            default:
                // Still waiting - poll every 100ms
                try await Task.sleep(nanoseconds: 100_000_000)
            }
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

    private func outputJSON(_ output: JoinOutput) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(output)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}

struct JoinOutput: Codable {
    let success: Bool
    let status: String
    let conversationId: String?
    let conversationName: String?
}
