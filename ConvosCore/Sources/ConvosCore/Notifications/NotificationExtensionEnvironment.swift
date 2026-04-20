import Foundation

enum NotificationExtensionEnvironmentError: Error {
    case failedRetrievingSecureConfiguration
}

/// Helper for notification extensions to get the correct environment configuration
public struct NotificationExtensionEnvironment {
    nonisolated(unsafe) private static var cachedEnvironment: AppEnvironment?

    /// Returns the environment configuration stored by the main app in the shared keychain.
    /// The result is cached after first retrieval.
    public static func getEnvironment() throws -> AppEnvironment {
        if let cached = cachedEnvironment {
            return cached
        }

        guard let storedEnvironment = AppEnvironment.retrieveSecureConfigurationForNotificationExtension() else {
            Log.warning("No stored environment configuration found - main app should store config before NSE runs")
            throw NotificationExtensionEnvironmentError.failedRetrievingSecureConfiguration
        }

        cachedEnvironment = storedEnvironment
        Log.info("Environment configuration loaded and cached: \(storedEnvironment.name)")
        return storedEnvironment
    }

    /// Creates a `CachedPushNotificationHandler` for the current environment.
    /// Call this once and store the result as a global singleton.
    public static func createPushNotificationHandler(
        platformProviders: PlatformProviders
    ) throws -> CachedPushNotificationHandler {
        let environment = try getEnvironment()
        let databaseManager = DatabaseManager(environment: environment)
        let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)

        Log.info("Creating CachedPushNotificationHandler with environment: \(environment.name)")

        CachedPushNotificationHandler.initialize(
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            environment: environment,
            identityStore: identityStore,
            platformProviders: platformProviders
        )
        return CachedPushNotificationHandler.shared
    }
}
