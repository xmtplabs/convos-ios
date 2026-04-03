import Foundation

private enum DMMetadataKey {
    static let allowsDMs: String = "allows_dms"
}

extension ProfileMetadata {
    public var allowsDMs: Bool {
        self[DMMetadataKey.allowsDMs]?.boolValue ?? false
    }

    public func withAllowsDMs(_ enabled: Bool) -> ProfileMetadata {
        var copy = self
        if enabled {
            copy[DMMetadataKey.allowsDMs] = .bool(true)
        } else {
            copy.removeValue(forKey: DMMetadataKey.allowsDMs)
        }
        return copy
    }
}

extension ProfileUpdate {
    public var allowsDMs: Bool {
        profileMetadata.allowsDMs
    }
}

extension MemberProfile {
    public var allowsDMs: Bool {
        profileMetadata.allowsDMs
    }
}
