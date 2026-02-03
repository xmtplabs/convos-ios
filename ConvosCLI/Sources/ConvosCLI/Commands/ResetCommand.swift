import ArgumentParser
import ConvosCore
import Foundation

struct Reset: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "reset",
        abstract: "Delete all local data (databases, identities, cached data)"
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force: Bool = false

    mutating func run() async throws {
        let dataDirectory = DataDirectory.resolve(override: options.dataDir)

        // Check if directory exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dataDirectory.basePath.path) else {
            print("No data directory found at: \(dataDirectory.basePath.path)")
            print("Nothing to delete.")
            return
        }

        // List what will be deleted
        let contents = try fileManager.contentsOfDirectory(
            at: dataDirectory.basePath,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        if contents.isEmpty {
            print("Data directory is empty: \(dataDirectory.basePath.path)")
            print("Nothing to delete.")
            return
        }

        // Show what will be deleted
        print("The following will be deleted:")
        print("  - All XMTP databases and encryption keys")
        print("  - All Convos local data")
        print("  - All keychain identities for this environment")
        print("")
        print("Data directory: \(dataDirectory.basePath.path)")
        print("Files: \(contents.count)")

        var totalSize: Int64 = 0
        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            totalSize += Int64(resourceValues.fileSize ?? 0)
        }
        print("Total size: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
        print("")

        // Confirm unless --force is used
        if !force {
            print("Are you sure you want to delete all data? This cannot be undone.")
            print("Type 'yes' to confirm: ", terminator: "")

            guard let response = readLine()?.lowercased(), response == "yes" else {
                print("Aborted.")
                return
            }
        }

        print("")
        print("Deleting all data...")

        // Initialize context to get access to session manager
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Use ConvosCore's deleteAllInboxesWithProgress to properly clean up
        // This handles: stopping services, deleting from database, clearing keychain
        for try await progress in context.session.deleteAllInboxesWithProgress() {
            switch progress {
            case .clearingDeviceRegistration:
                print("  Clearing device registration...")
            case let .stoppingServices(completed, total):
                print("  Stopping services... (\(completed)/\(total))")
            case .deletingFromDatabase:
                print("  Deleting from database...")
            case .completed:
                print("  Cleanup completed.")
            }
        }

        // Now delete the data directory to remove any remaining files
        try fileManager.removeItem(at: dataDirectory.basePath)

        print("")
        print("All data deleted successfully.")
    }
}
