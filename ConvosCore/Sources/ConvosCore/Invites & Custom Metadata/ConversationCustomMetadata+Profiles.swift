import Foundation
import SwiftProtobuf

// MARK: - ConversationCustomMetadata + Profiles

extension ConversationCustomMetadata {
    /// Create metadata with description and profiles
    public init(profiles: [ConversationProfile]) {
        self.init()
        self.profiles = profiles
    }

    /// Add or update a profile in the metadata
    /// - Parameter profile: The profile to add or update (matched by inboxId)
    public mutating func upsertProfile(_ profile: ConversationProfile) {
        if let index = profiles.firstIndex(where: { $0.inboxID == profile.inboxID }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
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

// MARK: - DBMemberProfile + ConversationProfile

extension DBMemberProfile {
    var conversationProfile: ConversationProfile? {
        ConversationProfile(inboxIdString: inboxId, name: name, imageUrl: avatar)
    }
}
