import Foundation
import GRDB

/// Minimal surface the NSE handler needs from a `MessagingService`: process
/// a push payload, tear down when rotated out. Kept separate from
/// `MessagingServiceProtocol` so tests can substitute a stub without
/// having to mock the main app's whole messaging-service surface.
public protocol PushNotificationProcessing: AnyObject, Sendable {
    func processPushNotification(payload: PushNotificationPayload) async throws -> DecodedNotificationContent?
    func stop()
}

/// Constructs a push-notification-capable service for a given identity.
/// Injected into `CachedPushNotificationHandler` so the NSE's caching
/// logic can be tested without firing a real `AuthorizeInboxOperation`
/// or a real XMTP client.
public protocol PushNotificationServiceFactoryProtocol: Sendable {
    func makeService(
        inboxId: String,
        clientId: String,
        overrideJWTToken: String?
    ) -> any PushNotificationProcessing
}

/// Production factory — thin wrapper around
/// `MessagingService.authorizedMessagingService`.
public struct PushNotificationServiceFactory: PushNotificationServiceFactoryProtocol {
    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private let platformProviders: PlatformProviders

    public init(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        identityStore: any KeychainIdentityStoreProtocol,
        platformProviders: PlatformProviders
    ) {
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.environment = environment
        self.identityStore = identityStore
        self.platformProviders = platformProviders
    }

    public func makeService(
        inboxId: String,
        clientId: String,
        overrideJWTToken: String?
    ) -> any PushNotificationProcessing {
        MessagingService.authorizedMessagingService(
            for: inboxId,
            clientId: clientId,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            startsStreamingServices: false,
            overrideJWTToken: overrideJWTToken,
            platformProviders: platformProviders
        )
    }
}

// `MessagingService` already provides `processPushNotification(payload:)`
// (see `MessagingService+PushNotifications.swift`) and `stop()`. Adopting
// the protocol here is empty — it just names the conformance.
extension MessagingService: PushNotificationProcessing {}
