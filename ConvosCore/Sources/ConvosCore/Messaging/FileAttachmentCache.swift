import CryptoKit
import Foundation

public actor FileAttachmentCache {
    public static let shared: FileAttachmentCache = FileAttachmentCache()

    private let cacheDirectory: URL
    private let fileManager: FileManager = .default

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cacheDir.appendingPathComponent("FileAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func cachedFileURL(for attachmentKey: String, filename: String) -> URL? {
        let fileURL = cacheFileURL(for: attachmentKey, filename: filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        var mutableURL: URL = fileURL
        var resourceValues: URLResourceValues = URLResourceValues()
        resourceValues.contentAccessDate = Date()
        try? mutableURL.setResourceValues(resourceValues)
        return fileURL
    }

    public func cacheFile(data: Data, for attachmentKey: String, filename: String) throws -> URL {
        let dirURL = cacheSubdirectory(for: attachmentKey)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public func cacheFile(from sourceURL: URL, for attachmentKey: String, filename: String) throws -> URL {
        let dirURL = cacheSubdirectory(for: attachmentKey)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let destURL = dirURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destURL.path) {
            return destURL
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    private func cacheFileURL(for attachmentKey: String, filename: String) -> URL {
        cacheSubdirectory(for: attachmentKey).appendingPathComponent(filename)
    }

    private func cacheSubdirectory(for attachmentKey: String) -> URL {
        let hash = SHA256.hash(data: Data(attachmentKey.utf8))
        let hashString = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hashString, isDirectory: true)
    }
}
