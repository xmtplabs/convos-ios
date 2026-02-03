import ArgumentParser
import ConvosCore
import Foundation

@main
struct ConvosCLI: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "convos",
        abstract: "Command-line interface for Convos messaging",
        version: "0.1.0",
        subcommands: [
            ListConversations.self,
            ListMessages.self,
            Send.self,
            Receive.self,
            React.self,
            CreateConversation.self,
            Join.self,
            Invite.self,
            Reset.self,
            Daemon.self,
            TUI.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - Global Options

struct GlobalOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Path to data directory (default: ~/.local/share/convos)")
    var dataDir: String?

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Option(name: .long, help: "Output format: text, json")
    var output: OutputFormat = .text

    @Option(name: .long, help: "Environment: local, dev, production (default: dev)")
    var environment: CLIEnvironment = .dev
}

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
}
