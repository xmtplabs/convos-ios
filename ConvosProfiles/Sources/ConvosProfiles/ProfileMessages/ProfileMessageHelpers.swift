import ConvosAppData
import Foundation

// MARK: - MemberProfile + Helpers

extension MemberProfile {
    public var inboxIdString: String {
        inboxID.toHexString()
    }

    public init?(
        inboxIdString: String,
        name: String? = nil,
        encryptedImage: EncryptedProfileImageRef? = nil,
        metadata: ProfileMetadata? = nil
    ) {
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
        if let metadata, !metadata.isEmpty {
            self.metadata = metadata.asProtoMap
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

// MARK: - MetadataValue Helpers

public enum ProfileMetadataValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

public typealias ProfileMetadata = [String: ProfileMetadataValue]

extension MetadataValue {
    public init(_ value: ProfileMetadataValue) {
        self.init()
        switch value {
        case .string(let s):
            self.value = .stringValue(s)
        case .number(let n):
            self.value = .numberValue(n)
        case .bool(let b):
            self.value = .boolValue(b)
        }
    }

    public var typed: ProfileMetadataValue? {
        switch value {
        case .stringValue(let s):
            .string(s)
        case .numberValue(let n):
            .number(n)
        case .boolValue(let b):
            .bool(b)
        case nil:
            nil
        }
    }
}

extension Dictionary where Key == String, Value == MetadataValue {
    public var asProfileMetadata: ProfileMetadata {
        compactMapValues { $0.typed }
    }
}

extension ProfileMetadata {
    public var asProtoMap: [String: MetadataValue] {
        mapValues { MetadataValue($0) }
    }
}

// MARK: - ProfileUpdate Convenience

extension ProfileUpdate {
    public init(name: String?, encryptedImage: EncryptedProfileImageRef? = nil, metadata: ProfileMetadata? = nil) {
        self.init()
        if let name {
            self.name = name
        }
        if let encryptedImage {
            self.encryptedImage = encryptedImage
        }
        if let metadata, !metadata.isEmpty {
            self.metadata = metadata.asProtoMap
        }
    }

    public var profileMetadata: ProfileMetadata {
        metadata.asProfileMetadata
    }
}

extension MemberProfile {
    public var profileMetadata: ProfileMetadata {
        metadata.asProfileMetadata
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
