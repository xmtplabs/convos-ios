import Foundation
import SwiftProtobuf

// MARK: - EncryptedImageRef + Validation

extension EncryptedImageRef {
    public var isValid: Bool {
        !url.isEmpty && salt.count == 32 && nonce.count == 12
    }
}

// MARK: - ConversationProfile + Helpers

extension ConversationProfile {
    /// InboxId as hex string (convenience accessor for bytes field)
    public var inboxIdString: String {
        inboxID.hexEncodedString()
    }

    /// Returns the effective image URL (prefers encrypted if valid, falls back to legacy)
    public var effectiveImageUrl: String? {
        if hasEncryptedImage, encryptedImage.isValid {
            return encryptedImage.url
        }
        if hasImage {
            return image
        }
        return nil
    }

    /// Failable initializer with hex-encoded inbox ID string
    /// - Parameters:
    ///   - inboxIdString: Hex-encoded inbox ID (XMTP v3 format)
    ///   - name: Optional display name
    ///   - imageUrl: Optional avatar URL (legacy unencrypted)
    /// - Returns: ConversationProfile if inbox ID is valid hex, nil otherwise
    public init?(inboxIdString: String, name: String? = nil, imageUrl: String? = nil) {
        guard let inboxIdBytes = Data(hexString: inboxIdString), !inboxIdBytes.isEmpty else {
            return nil
        }

        self.init()
        self.inboxID = inboxIdBytes

        if let name = name {
            self.name = name
        } else {
            self.clearName()
        }
        if let imageUrl = imageUrl {
            self.image = imageUrl
        } else {
            self.clearImage()
        }
    }

    /// Failable initializer with encrypted image reference
    /// - Parameters:
    ///   - inboxIdString: Hex-encoded inbox ID (XMTP v3 format)
    ///   - name: Optional display name
    ///   - encryptedImageRef: Encrypted image reference
    /// - Returns: ConversationProfile if inbox ID is valid hex, nil otherwise
    public init?(inboxIdString: String, name: String? = nil, encryptedImageRef: EncryptedImageRef) {
        guard let inboxIdBytes = Data(hexString: inboxIdString), !inboxIdBytes.isEmpty else {
            return nil
        }

        self.init()
        self.inboxID = inboxIdBytes

        if let name = name {
            self.name = name
        } else {
            self.clearName()
        }
        self.encryptedImage = encryptedImageRef
        self.clearImage()
    }
}
