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

// MARK: - ConversationProfile + Merging

extension ConversationProfile {
    /// Returns this profile layered over an existing entry, preserving fields
    /// the incoming side does not carry. A device whose local state is
    /// incomplete (fresh pairing, mid-hydration) must never downgrade the
    /// richer entry already in group metadata by replacing it wholesale.
    ///
    /// Semantics:
    /// - `name`: incoming wins, including an explicit clear.
    /// - image fields: when the incoming profile carries no avatar of either
    ///   kind, the existing `encryptedImage`/legacy `image` are preserved.
    ///   When it carries one, its own fields stand (the initializers already
    ///   clear the variant they don't use). Removal is an explicit operation
    ///   (`clearProfileAvatar`), never a side effect of empty local state.
    /// - `connections`: preserved when absent on the incoming side - it lives
    ///   only in remote metadata and is managed by its own update/clear APIs.
    public func merged(over existing: ConversationProfile) -> ConversationProfile {
        var result = self
        let carriesImage = (hasEncryptedImage && encryptedImage.isValid) || hasImage
        if !carriesImage {
            if existing.hasEncryptedImage {
                result.encryptedImage = existing.encryptedImage
            }
            if existing.hasImage {
                result.image = existing.image
            }
        }
        if !hasConnections, existing.hasConnections {
            result.connections = existing.connections
        }
        return result
    }
}

// MARK: - ConversationCustomMetadata + Profiles

extension ConversationCustomMetadata {
    /// Add or update a profile in the metadata
    /// - Parameter profile: The profile to add or update (matched by inboxId)
    public mutating func upsertProfile(_ profile: ConversationProfile) {
        if let index = profiles.firstIndex(where: { $0.inboxID == profile.inboxID }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Add or update a profile, preserving fields the incoming side does not
    /// carry (see `ConversationProfile.merged(over:)`). Use this instead of
    /// `upsertProfile` for writes built from local state, which may be poorer
    /// than what the metadata already holds.
    public mutating func mergeProfile(_ incoming: ConversationProfile) {
        guard let existing = profiles.first(where: { $0.inboxID == incoming.inboxID }) else {
            upsertProfile(incoming)
            return
        }
        upsertProfile(incoming.merged(over: existing))
    }

    /// Remove a profile by inbox ID
    /// - Parameter inboxId: The inbox ID to remove (hex string)
    /// - Returns: true if a profile was removed
    @discardableResult
    public mutating func removeProfile(inboxId: String) -> Bool {
        guard let inboxIdBytes = Data(hexString: inboxId) else {
            return false
        }
        if let index = profiles.firstIndex(where: { $0.inboxID == inboxIdBytes }) {
            profiles.remove(at: index)
            return true
        }
        return false
    }

    /// Find a profile by inbox ID
    /// - Parameter inboxId: The inbox ID to search for (hex string)
    /// - Returns: The profile if found, nil otherwise
    public func findProfile(inboxId: String) -> ConversationProfile? {
        guard let inboxIdBytes = Data(hexString: inboxId) else {
            return nil
        }
        return profiles.first { $0.inboxID == inboxIdBytes }
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
    /// Initialize Data from a hex string
    public init?(hexString: String) {
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
    public func toHexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
