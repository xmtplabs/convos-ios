import Foundation
// FIXME(stage6e-residual): `@preconcurrency import XMTPiOS` remains
// because the inline-attachment recovery path resolves the message's
// decoded content as XIP-typed `Attachment` / `Reply` payloads (the
// codec output types are XMTPiOS-owned). The provider entry-point has
// migrated to `MessagingConversations.findMessage` (Stage 6e Phase B-2);
// when the XIP payload types move under `MessagingMessagePayload` the
// XMTPiOS import drops.
@preconcurrency import XMTPiOS

public enum InlineAttachmentRecoveryError: Error {
    case messageNotFound
    case notAnAttachment
    case noProviderAvailable
}

public actor InlineAttachmentRecovery {
    public static let shared: InlineAttachmentRecovery = .init()

    private var provider: (any MessagingConversations)?

    private init() {}

    /// Stage 6e Phase B-2: provider migrated from the legacy
    /// `ConversationsProvider` (XMTPiOS-typed) to the abstraction's
    /// `MessagingConversations`. The XIP-payload resolution still uses
    /// XMTPiOS-typed `Attachment` / `Reply` content because the codec
    /// payload types are owned by XMTPiOS.
    public func setProvider(_ provider: (any MessagingConversations)?) {
        self.provider = provider
    }

    public func recoverData(messageId: String) async throws -> Data {
        guard let provider else {
            throw InlineAttachmentRecoveryError.noProviderAvailable
        }

        guard let decoded = try await provider.findMessage(messageId: messageId) else {
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
