import Foundation

// MARK: - HMAC keys

/// A single HMAC key used for push-topic authentication, pulled from
/// libxmtp's `Conversation.getHmacKeys()` surface.
///
/// Convos does not inspect these bytes today (see audit §4 "Pass
/// through opaque"). Multi-installation device-sync will need them.
public struct MessagingHmacKey: Hashable, Sendable, Codable {
    public let key: Data
    public let thirtyDayPeriodsSinceEpoch: Int32

    public init(key: Data, thirtyDayPeriodsSinceEpoch: Int32) {
        self.key = key
        self.thirtyDayPeriodsSinceEpoch = thirtyDayPeriodsSinceEpoch
    }
}

/// Bag of HMAC keys keyed by push topic.
public struct MessagingHmacKeys: Hashable, Sendable, Codable {
    public let keysByTopic: [String: [MessagingHmacKey]]

    public init(keysByTopic: [String: [MessagingHmacKey]]) {
        self.keysByTopic = keysByTopic
    }
}

// MARK: - Archive options

/// Options forwarded to `createArchive` / `sendSyncArchive` /
/// `processSyncArchive`. Kept opaque; the adapter is responsible
/// for translating into the SDK-native `ArchiveOptions`.
public struct MessagingArchiveOptions: Sendable {
    public var includeConsent: Bool
    public var includeHmacKeys: Bool
    public var includeMessages: Bool
    public var startNs: Int64?
    public var endNs: Int64?

    public init(
        includeConsent: Bool = true,
        includeHmacKeys: Bool = true,
        includeMessages: Bool = true,
        startNs: Int64? = nil,
        endNs: Int64? = nil
    ) {
        self.includeConsent = includeConsent
        self.includeHmacKeys = includeHmacKeys
        self.includeMessages = includeMessages
        self.startNs = startNs
        self.endNs = endNs
    }
}

// MARK: - Device sync API

/// Device-sync surface used by multi-installation replication.
///
/// Not currently called in Convos (`deviceSyncEnabled: false` in
/// `InboxStateMachine.swift:1119`, audit open question #3), but the
/// abstraction carries it so Stage 5+ does not need to add a new
/// top-level API.
public protocol MessagingDeviceSync: Sendable {
    func sendSyncRequest(
        options: MessagingArchiveOptions,
        serverUrl: String?
    ) async throws

    func sendSyncArchive(
        options: MessagingArchiveOptions,
        serverUrl: String?,
        pin: String
    ) async throws

    func processSyncArchive(pin: String?) async throws

    func syncAllDeviceSyncGroups() async throws -> MessagingSyncSummary

    func createArchive(
        path: String,
        encryptionKey: Data,
        options: MessagingArchiveOptions
    ) async throws

    func importArchive(
        path: String,
        encryptionKey: Data
    ) async throws
}
