import ConvosAppData
import Foundation
@preconcurrency import XMTPiOS

public enum ProfileSnapshotBuilder {
    public static func buildSnapshot(
        group: XMTPiOS.Group,
        memberInboxIds: [String]
    ) async throws -> ProfileSnapshot {
        let messages = try await group.messages(
            limit: Constant.maxMessagesToScan,
            direction: .descending
        )

        var profilesByInboxId: [String: MemberProfile] = [:]
        var latestSnapshotProfiles: [String: MemberProfile] = [:]

        for message in messages {
            guard let contentType = try? message.encodedContent.type else { continue }

            if contentType == ContentTypeProfileUpdate {
                processProfileUpdate(message: message, into: &profilesByInboxId)
            } else if contentType == ContentTypeProfileSnapshot, latestSnapshotProfiles.isEmpty {
                processProfileSnapshot(message: message, into: &latestSnapshotProfiles)
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

    private static func processProfileUpdate(
        message: DecodedMessage,
        into profiles: inout [String: MemberProfile]
    ) {
        let senderInboxId = message.senderInboxId
        guard profiles[senderInboxId] == nil else { return }
        guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else { return }
        guard let inboxIdBytes = Data(hexString: senderInboxId), !inboxIdBytes.isEmpty else { return }

        var memberProfile = MemberProfile()
        memberProfile.inboxID = inboxIdBytes
        if update.hasName {
            memberProfile.name = update.name
        }
        if update.hasEncryptedImage {
            memberProfile.encryptedImage = update.encryptedImage
        }
        memberProfile.memberKind = update.memberKind
        profiles[senderInboxId] = memberProfile
    }

    private static func processProfileSnapshot(
        message: DecodedMessage,
        into profiles: inout [String: MemberProfile]
    ) {
        guard let snapshot = try? ProfileSnapshotCodec().decode(content: message.encodedContent) else { return }
        for profile in snapshot.profiles {
            let inboxId = profile.inboxIdString
            guard !inboxId.isEmpty else { continue }
            profiles[inboxId] = profile
        }
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
        if encoded.content.count > Constant.snapshotSizeWarningThreshold {
            print("[ConvosProfiles] Large ProfileSnapshot: \(encoded.content.count) bytes, \(snapshot.profiles.count) profiles")
        }
        _ = try await group.send(encodedContent: encoded)
    }

    private enum Constant {
        static let maxMessagesToScan: Int = 500
        static let snapshotSizeWarningThreshold: Int = 50_000
    }
}
