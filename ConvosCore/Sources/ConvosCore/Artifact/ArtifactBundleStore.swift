import CryptoKit
import Foundation

public enum ArtifactBundleStoreError: Error, Equatable {
    case localFileMissing
    case malformedAttachmentKey
}

public actor ArtifactBundleStore {
    public static let shared: ArtifactBundleStore = .init()

    private let cacheDirectory: URL
    private let fileManager: FileManager = .default
    private var cachedBundles: [String: ArtifactBundle] = [:]
    private var inFlightTasks: [String: Task<ArtifactBundle, Error>] = [:]

    private let attachmentLoader: any RemoteAttachmentLoaderProtocol

    public init(attachmentLoader: any RemoteAttachmentLoaderProtocol = RemoteAttachmentLoader()) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cacheDir.appendingPathComponent("ArtifactBundles", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.attachmentLoader = attachmentLoader
    }

    public func bundle(for attachmentKey: String, filename: String?) async throws -> ArtifactBundle {
        if let cached = cachedBundles[attachmentKey] {
            return cached
        }
        if let inFlight = inFlightTasks[attachmentKey] {
            return try await inFlight.value
        }

        let task = Task<ArtifactBundle, Error> {
            try await loadAndExtract(attachmentKey: attachmentKey, filename: filename)
        }
        inFlightTasks[attachmentKey] = task

        do {
            let bundle = try await task.value
            inFlightTasks[attachmentKey] = nil
            cachedBundles[attachmentKey] = bundle
            return bundle
        } catch {
            inFlightTasks[attachmentKey] = nil
            throw error
        }
    }

    private func loadAndExtract(attachmentKey: String, filename: String?) async throws -> ArtifactBundle {
        let extractedDirectory = self.extractedDirectory(for: attachmentKey)

        if fileManager.fileExists(atPath: extractedDirectory.appendingPathComponent(ArtifactBundleExtractor.manifestFilename).path) {
            return try ArtifactBundleExtractor.bundle(at: extractedDirectory)
        }

        let zipURL = try await fetchZIP(attachmentKey: attachmentKey, filename: filename)
        return try ArtifactBundleExtractor.extract(zipURL: zipURL, into: extractedDirectory)
    }

    private func fetchZIP(attachmentKey: String, filename: String?) async throws -> URL {
        let resolvedFilename = filename ?? "bundle.artifact"
        let cache = FileAttachmentCache.shared

        if let cached = await cache.cachedFileURL(for: attachmentKey, filename: resolvedFilename) {
            return cached
        }

        if attachmentKey.hasPrefix("file://") {
            let path = String(attachmentKey.dropFirst("file://".count))
            let sourceURL = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: path) {
                return try await cache.cacheFile(from: sourceURL, for: attachmentKey, filename: resolvedFilename)
            }
            let messageId = Self.extractMessageId(from: sourceURL)
            if let messageId {
                let data = try await InlineAttachmentRecovery.shared.recoverData(messageId: messageId)
                return try await cache.cacheFile(data: data, for: attachmentKey, filename: resolvedFilename)
            }
            throw ArtifactBundleStoreError.localFileMissing
        }

        let loaded = try await attachmentLoader.loadAttachmentData(from: attachmentKey)
        return try await cache.cacheFile(data: loaded.data, for: attachmentKey, filename: resolvedFilename)
    }

    private func extractedDirectory(for attachmentKey: String) -> URL {
        let hash = SHA256.hash(data: Data(attachmentKey.utf8))
        let hashString = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hashString, isDirectory: true)
    }

    private static func extractMessageId(from fileURL: URL) -> String? {
        let filename = fileURL.lastPathComponent
        guard let underscoreIndex = filename.firstIndex(of: "_") else { return nil }
        let messageId = String(filename[filename.startIndex..<underscoreIndex])
        return messageId.isEmpty ? nil : messageId
    }
}
