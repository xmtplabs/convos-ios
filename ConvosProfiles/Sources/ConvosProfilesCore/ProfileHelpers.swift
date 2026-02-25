import Foundation

// MARK: - EncryptedImageRef + Validation

extension EncryptedImageRef {
    /// Checks if the encrypted image reference has valid components
    public var isValid: Bool {
        !url.isEmpty && salt.count == 32 && nonce.count == 12
    }
}

// MARK: - ConversationProfile + Helpers

extension ConversationProfile {
    /// InboxId as hex string (convenience accessor for bytes field)
    public var inboxIdString: String {
        inboxID.toHexString()
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
        inboxID = inboxIdBytes

        if let name {
            self.name = name
        } else {
            clearName()
        }
        if let imageUrl {
            image = imageUrl
        } else {
            clearImage()
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
        inboxID = inboxIdBytes

        if let name {
            self.name = name
        } else {
            clearName()
        }
        encryptedImage = encryptedImageRef
        clearImage()
    }
}

// MARK: - Profile Collection Helpers

extension Array where Element == ConversationProfile {
    /// Add or update a profile (matched by inboxId)
    public mutating func upsert(_ profile: ConversationProfile) {
        if let index = firstIndex(where: { $0.inboxID == profile.inboxID }) {
            self[index] = profile
        } else {
            append(profile)
        }
    }

    /// Remove a profile by inbox ID
    /// - Parameter inboxId: The inbox ID to remove (hex string)
    /// - Returns: true if a profile was removed
    @discardableResult
    public mutating func remove(inboxId: String) -> Bool {
        guard let inboxIdBytes = Data(hexString: inboxId) else {
            return false
        }
        if let index = firstIndex(where: { $0.inboxID == inboxIdBytes }) {
            remove(at: index)
            return true
        }
        return false
    }

    /// Find a profile by inbox ID
    /// - Parameter inboxId: The inbox ID to search for (hex string)
    /// - Returns: The profile if found, nil otherwise
    public func find(inboxId: String) -> ConversationProfile? {
        guard let inboxIdBytes = Data(hexString: inboxId) else {
            return nil
        }
        return first { $0.inboxID == inboxIdBytes }
    }
}

// MARK: - Data Hex Helpers

extension Data {
    /// Initialize Data from a hex string (package-internal)
    package init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Convert data to hex string
    func toHexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
