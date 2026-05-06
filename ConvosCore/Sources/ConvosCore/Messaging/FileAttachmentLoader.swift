import Foundation

public enum FileAttachmentLoaderError: Error {
    case localFileMissing
}

public enum FileAttachmentLoader {
    public static func loadFile(
        for attachment: HydratedAttachment,
        attachmentLoader: any RemoteAttachmentLoaderProtocol = RemoteAttachmentLoader()
    ) async throws -> URL {
        let filename = attachment.filename ?? "attachment"
        let cache = FileAttachmentCache.shared

        if let cached = await cache.cachedFileURL(for: attachment.key, filename: filename) {
            return cached
        }

        if attachment.key.hasPrefix("file://") {
            let path = String(attachment.key.dropFirst("file://".count))
            let sourceURL = URL(fileURLWithPath: path)

            if FileManager.default.fileExists(atPath: path) {
                return try await cache.cacheFile(from: sourceURL, for: attachment.key, filename: filename)
            }

            if let messageId = extractMessageId(from: sourceURL) {
                let data = try await InlineAttachmentRecovery.shared.recoverData(messageId: messageId)
                return try await cache.cacheFile(data: data, for: attachment.key, filename: filename)
            }

            throw FileAttachmentLoaderError.localFileMissing
        }

        let loaded = try await attachmentLoader.loadAttachmentData(from: attachment.key)
        return try await cache.cacheFile(data: loaded.data, for: attachment.key, filename: filename)
    }

    private static func extractMessageId(from fileURL: URL) -> String? {
        let filename = fileURL.lastPathComponent
        guard let underscoreIndex = filename.firstIndex(of: "_") else { return nil }
        let messageId = String(filename[filename.startIndex..<underscoreIndex])
        return messageId.isEmpty ? nil : messageId
    }
}
