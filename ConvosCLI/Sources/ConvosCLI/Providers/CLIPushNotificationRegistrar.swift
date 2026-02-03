import ConvosCore
import Foundation

/// CLI push notification registrar - no-op since CLI uses polling/streaming instead
public final class CLIPushNotificationRegistrar: PushNotificationRegistrarProtocol, Sendable {
    public var token: String? { nil }

    public init() {}

    public func save(token: String) {
        // No-op: CLI doesn't use push notifications
    }

    public func requestNotificationAuthorizationIfNeeded() async -> Bool {
        // CLI doesn't need push notification authorization
        false
    }
}
