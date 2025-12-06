import ConvosCore
import SwiftUI
import UserNotifications
import XMTPiOS

@main
struct ConvosApp: App {
    @UIApplicationDelegateAdaptor(ConvosAppDelegate.self) private var appDelegate: ConvosAppDelegate

    let session: any SessionManagerProtocol
    let conversationsViewModel: ConversationsViewModel
    let quicknameViewModel: QuicknameSettingsViewModel = .shared

    init() {
        let environment = ConfigManager.shared.currentEnvironment
        // Configure logging (automatically disabled in production)
        ConvosLog.configure(environment: environment)

        // only enable LibXMTP logging in non-production environments
        if !environment.isProduction {
            Log.info("Activating LibXMTP Log Writer...")
            Client.activatePersistentLibXMTPLogWriter(
                logLevel: .debug,
                rotationSchedule: .hourly,
                maxFiles: 10,
                customLogDirectory: environment.defaultXMTPLogsDirectoryURL
            )
        }
        Log.info("App starting with environment: \(environment)")

        // Run migration to wipe app data (must be done synchronously before app starts)
        Self.runDataWipeMigrationSync(environment: environment)

        // Configure Firebase before creating ConvosClient
        // This prevents SessionManager trying to use AppCheck before it's configured
        switch environment {
        case .tests:
            Log.info("Running in test environment, skipping Firebase config...")
        default:
            if let url = ConfigManager.shared.currentEnvironment.firebaseConfigURL {
                FirebaseHelperCore.configure(with: url)
            } else {
                Log.error("Missing Firebase plist URL for current environment")
            }
        }

        let convos: ConvosClient = .client(environment: environment)
        self.session = convos.session
        self.conversationsViewModel = .init(session: session)
        appDelegate.session = session
    }

    var body: some Scene {
        WindowGroup {
            ConversationsView(
                viewModel: conversationsViewModel,
                quicknameViewModel: quicknameViewModel
            )
            .withSafeAreaEnvironment()
        }
    }

    // MARK: - Migration

    private static func runDataWipeMigrationSync(environment: AppEnvironment) {
        let migrationKey = "data_wipe_migration_v1_0_completed"
        let defaults = UserDefaults.standard

        // Check if migration has already been run
        guard !defaults.bool(forKey: migrationKey) else {
            Log.info("Data wipe migration already completed, skipping")
            return
        }

        Log.info("Running data wipe migration...")

        // 1. Wipe documents directory
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documentsDirectory = documentsDirectory {
            do {
                let fileURLs = try FileManager.default.contentsOfDirectory(
                    at: documentsDirectory,
                    includingPropertiesForKeys: nil
                )
                for fileURL in fileURLs {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.info("Deleted: \(fileURL.lastPathComponent)")
                }
                Log.info("Successfully wiped documents directory")
            } catch {
                Log.error("Error wiping documents directory: \(error)")
            }
        }

        // 2. Wipe convos.sqlite and related files from defaultDatabasesDirectoryURL
        let databasesDirectory = environment.defaultDatabasesDirectoryURL
        let databaseFiles = [
            "convos.sqlite",
            "convos.sqlite-wal",
            "convos.sqlite-shm"
        ]

        for fileName in databaseFiles {
            let fileURL = databasesDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.info("Deleted database file: \(fileName)")
                } catch {
                    Log.error("Error deleting \(fileName): \(error)")
                }
            }
        }

        // 3. Mark migration as completed
        defaults.set(true, forKey: migrationKey)
        defaults.synchronize()
        Log.info("Data wipe migration completed and marked as done")
    }
}
