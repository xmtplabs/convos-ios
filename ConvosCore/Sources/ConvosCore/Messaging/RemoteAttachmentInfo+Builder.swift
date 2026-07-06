import Foundation
import XMTPiOS

extension MultiRemoteAttachment.RemoteAttachmentInfo {
    /// Build the wire attachment info from an encrypted-upload descriptor.
    /// `contentLength` is the encrypted payload byte count (per the XMTP proto),
    /// so no send path can emit 0/nil/plaintext.
    init(from prepared: PreparedBackgroundUpload) {
        self.init(
            url: prepared.assetURL,
            filename: prepared.filename,
            contentLength: prepared.encryptedContentLength,
            contentDigest: prepared.contentDigest,
            nonce: prepared.encryptionNonce,
            scheme: "https",
            salt: prepared.encryptionSalt,
            secret: prepared.encryptionSecret
        )
    }
}
