import ConvosAppData
import Foundation
import GRDB
@preconcurrency import XMTPiOS

public enum ProfileSnapshotBuilder {
    /// Builds the roster bundle a member publishes so new joiners learn
    /// everyone's profile at once (in-group messages do not reach members
    /// who join later, so this snapshot is the joiner's only source for
    /// pre-join members).
    ///
    /// The roster unions two sources, keyed by inbox id and filtered to the
    /// current `memberInboxIds`:
    /// - `dbProfiles`: the sender's authoritative per-conversation rows. These
    ///   include members the sender learned only via group appData (agents,
    ///   directly-added members) and members whose profile update has aged out
    ///   of the recent-message window.
    /// - the recent-message scan: profile updates (and a fallback snapshot)
    ///   from the last `maxMessagesToScan` messages. This catches an update
    ///   that has been synced but not yet flushed to the database.
    ///
    /// When both sources carry a member, the recent message wins per field and
    /// the database row fills any gap, so a freshly received update is honored
    /// without ever regressing a known name back to nothing.
    public static func buildSnapshot(
        group: XMTPiOS.Group,
        memberInboxIds: [String],
        dbProfiles: [MemberProfile] = []
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

        var dbProfilesByInboxId: [String: MemberProfile] = [:]
        for profile in dbProfiles {
            dbProfilesByInboxId[profile.inboxIdString] = profile
        }

        var result: [MemberProfile] = []
        for inboxId in memberInboxIds {
            let messageProfile = profilesByInboxId[inboxId] ?? latestSnapshotProfiles[inboxId]
            let dbProfile = dbProfilesByInboxId[inboxId]
            guard let merged = mergedProfile(base: dbProfile, overlay: messageProfile),
                  merged.hasSnapshotContent else {
                continue
            }
            result.append(merged)
        }

        return ProfileSnapshot(profiles: result)
    }

    /// Combines a database-sourced base with a recent-message overlay. The
    /// overlay wins on any field it sets; the base fills the rest. This keeps
    /// a just-received name while never clearing a known name when the overlay
    /// lacks one.
    private static func mergedProfile(
        base: MemberProfile?,
        overlay: MemberProfile?
    ) -> MemberProfile? {
        switch (base, overlay) {
        case (nil, nil):
            return nil
        case let (base?, nil):
            return base
        case let (nil, overlay?):
            return overlay
        case let (base?, overlay?):
            var merged = overlay
            // A usable (non-blank) incoming name wins; an empty or
            // whitespace-only incoming name (hasName=true but blank) must not
            // clobber a populated name back to "Somebody" - mirrors
            // DBMemberProfile.withInboundName.
            if !overlay.hasUsableName, base.hasName {
                merged.name = base.name
            }
            // Likewise a set-but-malformed incoming image ref must not clobber
            // a valid database image.
            if !overlay.hasUsableEncryptedImage, base.hasEncryptedImage {
                merged.encryptedImage = base.encryptedImage
            }
            if overlay.memberKind == .unspecified, base.memberKind != .unspecified {
                merged.memberKind = base.memberKind
            }
            if overlay.metadata.isEmpty, !base.metadata.isEmpty {
                merged.metadata = base.metadata
            }
            return merged
        }
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
        if !update.metadata.isEmpty {
            memberProfile.metadata = update.metadata
        }
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
        databaseReader: (any DatabaseReader)? = nil
    ) async throws {
        // Sync first, then read the member list, so a just-added joiner (for
        // example on the already-member re-publish path, where this
        // installation may not have synced the group yet) is in the roster
        // rather than filtered out by a stale member list.
        try await group.sync()
        let memberInboxIds = try await group.members.map(\.inboxId)
        let dbProfiles = try await fetchDBProfiles(
            databaseReader,
            conversationId: group.id,
            memberInboxIds: memberInboxIds
        )
        let snapshot = try await buildSnapshot(
            group: group,
            memberInboxIds: memberInboxIds,
            dbProfiles: dbProfiles
        )
        guard !snapshot.profiles.isEmpty else { return }

        let codec = ProfileSnapshotCodec()
        let encoded = try codec.encode(content: snapshot)
        if encoded.content.count > Constant.snapshotSizeWarningThreshold {
            Log.warning("Large ProfileSnapshot: \(encoded.content.count) bytes, \(snapshot.profiles.count) profiles")
        }
        _ = try await group.send(encodedContent: encoded)
    }

    /// Internal (not private) so the self-union behavior can be exercised in a
    /// unit test against a seeded database without a live XMTP group.
    static func fetchDBProfiles(
        _ databaseReader: (any DatabaseReader)?,
        conversationId: String,
        memberInboxIds: [String]
    ) async throws -> [MemberProfile] {
        guard let databaseReader else { return [] }
        return try await databaseReader.read { db in
            var byInboxId: [String: MemberProfile] = [:]
            for profile in try DBProfile.fetchAll(db, inboxIds: memberInboxIds) {
                let avatar = try DBProfileAvatar.fetchOne(db, inboxId: profile.inboxId, conversationId: conversationId)
                if let member = profile.snapshotMemberProfile(avatar: avatar) {
                    byInboxId[profile.inboxId] = member
                }
            }
            // Self is excluded from `profile`; fold in the locally-authored
            // `myProfile` rows so a sender always advertises its own identity
            // to joiners, even before it has published a ProfileUpdate into the
            // group or after that update has aged out of the message scan.
            for myProfile in try DBMyProfile.fetchAll(db, inboxIds: memberInboxIds) where byInboxId[myProfile.inboxId] == nil {
                let avatar = try DBProfileAvatar.fetchOne(db, inboxId: myProfile.inboxId, conversationId: conversationId)
                if let member = myProfile.snapshotMemberProfile(avatar: avatar) {
                    byInboxId[myProfile.inboxId] = member
                }
            }
            return Array(byInboxId.values)
        }
    }

    private enum Constant {
        static let maxMessagesToScan: Int = 500
        static let snapshotSizeWarningThreshold: Int = 50_000
    }
}

private extension MemberProfile {
    /// Whether the profile carries a usable, non-blank name. An empty or
    /// whitespace-only name is treated as absent so it never wins a merge or
    /// counts as snapshot content.
    var hasUsableName: Bool {
        guard hasName else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the profile carries a well-formed encrypted image ref (valid
    /// url, salt, and nonce). A set-but-malformed ref is treated as absent.
    var hasUsableEncryptedImage: Bool {
        hasEncryptedImage && encryptedImage.isValid
    }

    /// Whether the profile carries anything worth broadcasting. An inbox-id-only
    /// entry (a cleared profile with no usable name, image, agent kind, or
    /// metadata) conveys nothing to a joiner, so it is dropped from the snapshot.
    var hasSnapshotContent: Bool {
        hasUsableName || hasUsableEncryptedImage || memberKind != .unspecified || !metadata.isEmpty
    }
}
