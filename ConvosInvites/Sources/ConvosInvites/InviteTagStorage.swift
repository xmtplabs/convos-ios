import ConvosAppData
import Foundation
import Security
@preconcurrency import XMTPiOS

// MARK: - Invite Tag Storage Protocol

/// Protocol for reading and writing invite tags in group metadata
public protocol InviteTagStorageProtocol: Sendable {
    /// Get the invite tag for a group
    func getInviteTag(for group: XMTPiOS.Group) throws -> String

    /// Set the invite tag for a group
    func setInviteTag(_ tag: String, for group: XMTPiOS.Group) async throws

    /// Generate and set a new random invite tag (revokes existing invites)
    func regenerateInviteTag(for group: XMTPiOS.Group) async throws -> String
}

// MARK: - Default Implementation

/// Default implementation using ConversationCustomMetadata protobuf
///
/// Stores invite tags in the group's appData field using the same protobuf format
/// that Convos uses. This ensures consistency across all XMTP integrators.
///
/// The metadata is stored as compressed, base64-encoded protobuf data.
public struct ProtobufInviteTagStorage: InviteTagStorageProtocol {
    private static let tagLength: Int = 10

    public init() {}

    public func getInviteTag(for group: XMTPiOS.Group) throws -> String {
        let appDataString = try group.appData()
        let metadata = ConversationCustomMetadata.parseAppData(appDataString)

        guard !metadata.tag.isEmpty else {
            throw InviteTagStorageError.tagNotFound
        }

        return metadata.tag
    }

    public func setInviteTag(_ tag: String, for group: XMTPiOS.Group) async throws {
        let appDataString = try group.appData()
        var metadata = ConversationCustomMetadata.parseAppData(appDataString)
        metadata.tag = tag

        let newAppDataString = try metadata.toCompactString()
        try await group.updateAppData(appData: newAppDataString)
    }

    public func regenerateInviteTag(for group: XMTPiOS.Group) async throws -> String {
        let newTag = try generateRandomTag()
        try await setInviteTag(newTag, for: group)
        return newTag
    }

    // MARK: - Private Helpers

    private func generateRandomTag() throws -> String {
        let characters: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var randomBytes: [UInt8] = [UInt8](repeating: 0, count: Self.tagLength)
        let result = SecRandomCopyBytes(kSecRandomDefault, Self.tagLength, &randomBytes)
        guard result == errSecSuccess else {
            throw InviteTagStorageError.randomGenerationFailed
        }
        return String(randomBytes.map { characters[Int($0) % characters.count] })
    }
}

// MARK: - Errors

public enum InviteTagStorageError: Error, LocalizedError {
    case tagNotFound
    case encodingFailed
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .tagNotFound:
            return "Invite tag not found in group metadata"
        case .encodingFailed:
            return "Failed to encode invite tag data"
        case .randomGenerationFailed:
            return "SecRandomCopyBytes failed to generate random bytes"
        }
    }
}
