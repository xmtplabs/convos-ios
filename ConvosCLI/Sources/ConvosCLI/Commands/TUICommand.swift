import ArgumentParser
import ConvosCore
import Foundation

struct TUI: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "tui",
        abstract: "Interactive terminal UI for Convos"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        let app = await TUIApp(context: context)
        try await app.run()
    }
}
