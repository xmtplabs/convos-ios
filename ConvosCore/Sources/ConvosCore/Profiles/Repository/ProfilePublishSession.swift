import Foundation

/// A fully-resolved avatar reference, ready to advertise in a ProfileUpdate and
/// store in the local avatar slot. A plain (cleartext) avatar carries only a
/// `url`; the optional crypto fields are populated only for a legacy encrypted
/// avatar that is being re-advertised (image encryption is removed on the write
/// side, so newly published avatars are always plain).
struct PublishedAvatar: Sendable {
    let url: String
    let salt: Data?
    let nonce: Data?
    let key: Data?

    init(url: String, salt: Data? = nil, nonce: Data? = nil, key: Data? = nil) {
        self.url = url
        self.salt = salt
        self.nonce = nonce
        self.key = key
    }
}

/// The XMTP- and upload-facing seam the publisher delegates to, keeping
/// `ProfilePublisher` (and ConvosCore) free of XMTPiOS. The messaging layer
/// provides the concrete implementation when the publisher is wired up.
protocol ProfilePublishSession: Sendable {
    /// Uploads raw bytes, returning the URL they can be fetched from.
    func upload(_ data: Data, filename: String, contentType: String) async throws -> String

    /// Sends a ProfileUpdate carrying the name, metadata, and (optional) avatar
    /// to one conversation. Throws `ProfilePublishSessionError.conversationNotFound`
    /// when the conversation no longer exists, so the job can be dropped.
    func sendProfileUpdate(name: String?, metadata: ProfileMetadata?, avatar: PublishedAvatar?, conversationId: String) async throws
}
