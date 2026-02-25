import Foundation
import XMTPiOS

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

/// Default implementation using XMTP group appData
///
/// Stores invite tags in the group's appData field using a simple key-value format.
/// This is a basic implementation - apps may want to use protobuf for more complex metadata.
public struct XMTPInviteTagStorage: InviteTagStorageProtocol {
    private static let tagKey: String = "xmtp.invites.tag"
    private static let tagLength: Int = 10

    public init() {}

    public func getInviteTag(for group: XMTPiOS.Group) throws -> String {
        // Try to get tag from appData (returns String directly)
        let appDataString = try group.appData()
        if let tag = extractTag(from: appDataString) {
            return tag
        }

        // If no tag exists, this is an error - tag should be set on group creation
        throw InviteTagStorageError.tagNotFound
    }

    public func setInviteTag(_ tag: String, for group: XMTPiOS.Group) async throws {
        let existingString = (try? group.appData()) ?? ""
        let newString = updateTag(in: existingString, to: tag)
        try await group.updateAppData(appData: newString)
    }

    public func regenerateInviteTag(for group: XMTPiOS.Group) async throws -> String {
        let newTag = generateRandomTag()
        try await setInviteTag(newTag, for: group)
        return newTag
    }

    // MARK: - Private Helpers

    private func generateRandomTag() -> String {
        let characters: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<Self.tagLength).compactMap { _ in characters.randomElement() })
    }

    private func extractTag(from dataString: String) -> String? {
        // Simple key=value format: "xmtp.invites.tag=ABC123"
        let lines = dataString.split(separator: "\n")
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == Self.tagKey {
                return String(parts[1])
            }
        }
        return nil
    }

    private func updateTag(in dataString: String, to newTag: String) -> String {
        var lines = dataString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Find and update existing tag, or append new one
        var found: Bool = false
        for i in 0..<lines.count where lines[i].hasPrefix("\(Self.tagKey)=") {
            lines[i] = "\(Self.tagKey)=\(newTag)"
            found = true
            break
        }

        if !found {
            if !dataString.isEmpty && !dataString.hasSuffix("\n") {
                lines.append("")
            }
            lines.append("\(Self.tagKey)=\(newTag)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Errors

public enum InviteTagStorageError: Error, LocalizedError {
    case tagNotFound
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .tagNotFound:
            return "Invite tag not found in group metadata"
        case .encodingFailed:
            return "Failed to encode invite tag data"
        }
    }
}
