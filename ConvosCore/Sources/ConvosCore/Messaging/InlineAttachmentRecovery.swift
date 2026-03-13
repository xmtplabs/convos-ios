import Foundation
import XMTPiOS

public enum InlineAttachmentRecoveryError: Error {
    case messageNotFound
    case notAnAttachment
    case noProviderAvailable
}

public actor InlineAttachmentRecovery {
    public static let shared: InlineAttachmentRecovery = .init()

    private var provider: (any ConversationsProvider)?

    private init() {}

    public func setProvider(_ provider: (any ConversationsProvider)?) {
        self.provider = provider
    }

    public func recoverData(messageId: String) throws -> Data {
        guard let provider else {
            throw InlineAttachmentRecoveryError.noProviderAvailable
        }

        guard let decoded = try provider.findMessage(messageId: messageId) else {
            throw InlineAttachmentRecoveryError.messageNotFound
        }

        let content = try decoded.content() as Any

        if let attachment = content as? Attachment {
            try resave(data: attachment.data, messageId: messageId, filename: attachment.filename)
            return attachment.data
        }

        if let reply = content as? Reply, let attachment = reply.content as? Attachment {
            try resave(data: attachment.data, messageId: messageId, filename: attachment.filename)
            return attachment.data
        }

        throw InlineAttachmentRecoveryError.notAnAttachment
    }

    private func resave(data: Data, messageId: String, filename: String) throws {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = cacheDir.appendingPathComponent("InlineAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeFilename = "\(messageId)_\(filename)".replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent(safeFilename)
        try data.write(to: fileURL, options: .atomic)
    }
}
