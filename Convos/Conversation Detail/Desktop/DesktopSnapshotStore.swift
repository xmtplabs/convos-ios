import CryptoKit
import Foundation

/// Per-conversation cache of the last-rendered desktop web view. The stored
/// PNG is shown as a cover while that conversation's live web view reloads, so
/// the surface never flashes empty. Backed by files under `Caches/` (the OS
/// may evict them under storage pressure; the next load simply re-captures),
/// keyed by conversation id. The store trades in `Data` rather than images so
/// nothing non-`Sendable` crosses the actor boundary.
actor DesktopSnapshotStore {
    static let shared: DesktopSnapshotStore = DesktopSnapshotStore()

    private let cacheDirectory: URL
    private let fileManager: FileManager = .default

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cacheDir.appendingPathComponent("DesktopSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// The persisted PNG for a conversation, or nil if none has been captured
    /// yet (or the OS purged it).
    func snapshotData(for conversationId: String) -> Data? {
        try? Data(contentsOf: fileURL(for: conversationId))
    }

    /// Persists the latest desktop capture for a conversation, replacing any
    /// prior one.
    func store(_ pngData: Data, for conversationId: String) {
        try? pngData.write(to: fileURL(for: conversationId), options: .atomic)
    }

    private func fileURL(for conversationId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(cacheKey(for: conversationId)).png")
    }

    private func cacheKey(for conversationId: String) -> String {
        let hash = SHA256.hash(data: Data(conversationId.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
