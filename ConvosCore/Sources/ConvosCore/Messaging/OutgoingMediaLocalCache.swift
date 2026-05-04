import Foundation

/// In-memory map from a published attachment's StoredRemoteAttachment JSON key to the
/// sender's local copy of the file. Populated by the message writer at publish time
/// so outgoing video bubbles can play directly from disk instead of re-downloading the
/// encrypted asset from the storage backend on first render.
public actor OutgoingMediaLocalCache {
    public static let shared: OutgoingMediaLocalCache = .init()

    private var cache: [String: URL] = [:]

    public init() {}

    public func register(_ url: URL, for key: String) {
        cache[key] = url
    }

    public func url(for key: String) -> URL? {
        cache[key]
    }

    public func clear() {
        cache.removeAll()
    }
}
