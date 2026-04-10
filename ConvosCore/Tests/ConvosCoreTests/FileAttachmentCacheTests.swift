@testable import ConvosCore
import Foundation
import Testing

@Suite("FileAttachmentCache")
struct FileAttachmentCacheTests {
    private let cache: FileAttachmentCache = .shared

    @Test("returns nil for uncached attachment")
    func uncachedReturnsNil() async {
        let result = await cache.cachedFileURL(for: "nonexistent-key-\(UUID())", filename: "test.md")
        #expect(result == nil)
    }

    @Test("caches data and returns URL on subsequent lookup")
    func cacheDataAndRetrieve() async throws {
        let key = "test-cache-data-\(UUID())"
        let filename = "test.md"
        let data = Data("# Hello".utf8)

        let cachedURL = try await cache.cacheFile(data: data, for: key, filename: filename)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(cachedURL.lastPathComponent == filename)

        let retrieved = try Data(contentsOf: cachedURL)
        #expect(retrieved == data)

        let lookupURL = await cache.cachedFileURL(for: key, filename: filename)
        #expect(lookupURL != nil)
        #expect(lookupURL?.lastPathComponent == filename)
    }

    @Test("caches file from source URL")
    func cacheFromSourceURL() async throws {
        let key = "test-cache-source-\(UUID())"
        let filename = "source.txt"
        let data = Data("source content".utf8)

        let tempSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-source-\(UUID()).txt")
        try data.write(to: tempSource)
        defer { try? FileManager.default.removeItem(at: tempSource) }

        let cachedURL = try await cache.cacheFile(from: tempSource, for: key, filename: filename)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        let retrieved = try Data(contentsOf: cachedURL)
        #expect(retrieved == data)
    }

    @Test("different keys produce different cache paths")
    func differentKeysProduceDifferentPaths() async throws {
        let key1 = "key-a-\(UUID())"
        let key2 = "key-b-\(UUID())"
        let filename = "file.md"
        let data = Data("content".utf8)

        let url1 = try await cache.cacheFile(data: data, for: key1, filename: filename)
        let url2 = try await cache.cacheFile(data: data, for: key2, filename: filename)
        #expect(url1 != url2)
    }

    @Test("same key returns same cached file")
    func sameKeyReturnsSamePath() async throws {
        let key = "test-same-key-\(UUID())"
        let filename = "repeat.md"
        let data = Data("repeated".utf8)

        let url1 = try await cache.cacheFile(data: data, for: key, filename: filename)
        let url2 = await cache.cachedFileURL(for: key, filename: filename)
        #expect(url1 == url2)
    }
}
