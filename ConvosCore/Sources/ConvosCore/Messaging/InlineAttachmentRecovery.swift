import Foundation
// FIXME(stage4): Stage 4 migration is partial for this file. The
// `ConversationsProvider` protocol, `Attachment`, and `Reply` types
// are XMTPiOS-owned and still consumed here because Stage 4 does not
// migrate the XMTPClientProvider / legacy writer surface or the XIP
// payload types (audit §5 Stage 3/6). Once `ConversationsProvider` is
// replaced by `MessagingConversations.findMessage(...)` and the XIP
// payloads move under `MessagingMessagePayload`, this file can drop
// the XMTPiOS import and migrate fully.
@preconcurrency import XMTPiOS

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
        let safeFilename = "\(messageId)_\(filename)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let fileURL = dir.appendingPathComponent(safeFilename)
        try data.write(to: fileURL, options: .atomic)
    }
}
