import ConvosAppData
import Foundation
@preconcurrency import XMTPiOS

public enum ProfileSnapshotBuilder {
    public static func buildSnapshot(
        group: XMTPiOS.Group,
        memberInboxIds: [String]
    ) async throws -> ProfileSnapshot {
        let messages = try await group.messages(
            limit: 500,
            direction: .descending
        )

        var profilesByInboxId: [String: MemberProfile] = [:]
        var latestSnapshotProfiles: [String: MemberProfile] = [:]

        for message in messages {
            guard let contentType = try? message.encodedContent.type else { continue }

            if contentType == ContentTypeProfileUpdate {
                let senderInboxId = message.senderInboxId
                guard profilesByInboxId[senderInboxId] == nil else { continue }

                guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else {
                    continue
                }

                var memberProfile = MemberProfile()
                guard let inboxIdBytes = Data(hexString: senderInboxId), !inboxIdBytes.isEmpty else {
                    continue
                }
                memberProfile.inboxID = inboxIdBytes
                if update.hasName {
                    memberProfile.name = update.name
                }
                if update.hasEncryptedImage {
                    memberProfile.encryptedImage = update.encryptedImage
                }
                profilesByInboxId[senderInboxId] = memberProfile
            } else if contentType == ContentTypeProfileSnapshot, latestSnapshotProfiles.isEmpty {
                guard let snapshot = try? ProfileSnapshotCodec().decode(content: message.encodedContent) else {
                    continue
                }
                for profile in snapshot.profiles {
                    let inboxId = profile.inboxIdString
                    guard !inboxId.isEmpty else { continue }
                    latestSnapshotProfiles[inboxId] = profile
                }
            }

            let allMembersResolved = memberInboxIds.allSatisfy { profilesByInboxId[$0] != nil }
            if allMembersResolved { break }
        }

        var result: [MemberProfile] = []
        for inboxId in memberInboxIds {
            if let profile = profilesByInboxId[inboxId] {
                result.append(profile)
            } else if let snapshotProfile = latestSnapshotProfiles[inboxId] {
                result.append(snapshotProfile)
            }
        }

        return ProfileSnapshot(profiles: result)
    }

    public static func sendSnapshot(
        group: XMTPiOS.Group,
        memberInboxIds: [String]
    ) async throws {
        try await group.sync()
        let snapshot = try await buildSnapshot(group: group, memberInboxIds: memberInboxIds)
        guard !snapshot.profiles.isEmpty else { return }

        let codec = ProfileSnapshotCodec()
        let encoded = try codec.encode(content: snapshot)
        _ = try await group.send(encodedContent: encoded)
    }
}
