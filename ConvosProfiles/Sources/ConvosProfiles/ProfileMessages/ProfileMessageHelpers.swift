import ConvosAppData
import Foundation

// MARK: - MemberProfile + Helpers

extension MemberProfile {
    public var inboxIdString: String {
        inboxID.toHexString()
    }

    public init?(inboxIdString: String, name: String? = nil, encryptedImage: EncryptedProfileImageRef? = nil) {
        guard let inboxIdBytes = Data(hexString: inboxIdString), !inboxIdBytes.isEmpty else {
            return nil
        }
        self.init()
        inboxID = inboxIdBytes
        if let name {
            self.name = name
        }
        if let encryptedImage {
            self.encryptedImage = encryptedImage
        }
    }
}

// MARK: - EncryptedProfileImageRef + Validation

extension EncryptedProfileImageRef {
    public var isValid: Bool {
        !url.isEmpty && salt.count == 32 && nonce.count == 12
    }
}

// MARK: - EncryptedProfileImageRef <-> EncryptedImageRef Conversion

extension EncryptedProfileImageRef {
    public init(_ ref: EncryptedImageRef) {
        self.init()
        url = ref.url
        salt = ref.salt
        nonce = ref.nonce
    }

    public var asEncryptedImageRef: EncryptedImageRef {
        var ref = EncryptedImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
    }
}

// MARK: - ProfileUpdate Convenience

extension ProfileUpdate {
    public init(name: String?, encryptedImage: EncryptedProfileImageRef? = nil) {
        self.init()
        if let name {
            self.name = name
        }
        if let encryptedImage {
            self.encryptedImage = encryptedImage
        }
    }
}

// MARK: - ProfileSnapshot Convenience

extension ProfileSnapshot {
    public init(profiles: [MemberProfile]) {
        self.init()
        self.profiles = profiles
    }

    public func findProfile(inboxId: String) -> MemberProfile? {
        guard let inboxIdBytes = Data(hexString: inboxId) else {
            return nil
        }
        return profiles.first { $0.inboxID == inboxIdBytes }
    }
}
