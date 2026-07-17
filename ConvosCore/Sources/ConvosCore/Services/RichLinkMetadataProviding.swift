import Foundation

public protocol RichLinkMetadataProviding: Sendable {
    func fetchMetadata(for url: URL) async -> OpenGraphService.OpenGraphMetadata?
}

public enum RichLinkMetadata {
    private static let lock: NSLock = .init()
    nonisolated(unsafe) private static var _provider: (any RichLinkMetadataProviding)?

    public static func configure(_ provider: any RichLinkMetadataProviding) {
        lock.lock()
        defer { lock.unlock() }
        _provider = provider
    }

    public static var provider: (any RichLinkMetadataProviding)? {
        lock.lock()
        defer { lock.unlock() }
        return _provider
    }

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        _provider = nil
    }
}
