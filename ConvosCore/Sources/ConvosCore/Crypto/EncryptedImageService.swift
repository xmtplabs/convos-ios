import Foundation

public protocol EncryptedImageServiceProtocol: Sendable {
    func loadAndDecrypt(
        url: URL,
        salt: Data,
        nonce: Data,
        conversationId: String
    ) async throws -> Data
}

public actor EncryptedImageService: EncryptedImageServiceProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let keyCache: KeyCache
    private var inflightFetches: [String: Task<Data, Error>] = [:]

    public init(inboxStateManager: any InboxStateManagerProtocol) {
        self.inboxStateManager = inboxStateManager
        self.keyCache = KeyCache()
    }

    public func loadAndDecrypt(
        url: URL,
        salt: Data,
        nonce: Data,
        conversationId: String
    ) async throws -> Data {
        let groupKey = try await getOrFetchGroupKey(for: conversationId)

        let params = EncryptedImageParams(
            url: url,
            salt: salt,
            nonce: nonce,
            groupKey: groupKey
        )

        return try await EncryptedImageLoader.loadAndDecrypt(params: params)
    }

    private func getOrFetchGroupKey(for conversationId: String) async throws -> Data {
        if let cachedKey = keyCache.get(conversationId) {
            return cachedKey
        }

        if let existingTask = inflightFetches[conversationId] {
            return try await existingTask.value
        }

        let task = Task {
            try await self.fetchGroupKey(for: conversationId)
        }
        inflightFetches[conversationId] = task

        do {
            let key = try await task.value
            keyCache.set(key, for: conversationId)
            inflightFetches.removeValue(forKey: conversationId)
            return key
        } catch {
            inflightFetches.removeValue(forKey: conversationId)
            throw error
        }
    }

    private func fetchGroupKey(for conversationId: String) async throws -> Data {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ImageEncryptionError.missingEncryptionKey
        }

        guard let key = try group.imageEncryptionKey, !key.isEmpty else {
            throw ImageEncryptionError.missingEncryptionKey
        }

        return key
    }

    public func clearCache() {
        keyCache.removeAll()
    }

    public func clearCache(for conversationId: String) {
        keyCache.remove(conversationId)
    }
}

// KeyCache is @unchecked Sendable because NSCache is internally thread-safe
private final class KeyCache: @unchecked Sendable {
    private let cache: NSCache<NSString, NSData> = .init()

    init() {
        cache.countLimit = 100
    }

    func get(_ conversationId: String) -> Data? {
        cache.object(forKey: conversationId as NSString) as Data?
    }

    func set(_ key: Data, for conversationId: String) {
        cache.setObject(key as NSData, forKey: conversationId as NSString)
    }

    func remove(_ conversationId: String) {
        cache.removeObject(forKey: conversationId as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
