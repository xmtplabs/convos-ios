import Foundation
import GRDB

/// Result of one shadow comparison between the new canonical identity
/// (`DBProfile` / `DBProfileAvatar`) and the legacy `contact` table, over the
/// inboxes present in both.
struct ProfileShadowComparison: Sendable {
    let comparedCount: Int
    let nameMismatches: Int
    let avatarMismatches: Int
    let sampleInboxIds: [String]

    var hasDiscrepancies: Bool {
        nameMismatches > 0 || avatarMismatches > 0
    }

    var summary: String {
        "compared \(comparedCount), name mismatches \(nameMismatches), avatar mismatches \(avatarMismatches), samples \(sampleInboxIds)"
    }
}

/// Runs a background "shadow" comparison of the new profile identity against the
/// legacy `contact` table and logs discrepancies. The point is to surface
/// mirror/backfill bugs while the new system is still dormant, so they can be
/// fixed before the cutover flips reads to the repository. Read-only; changes
/// nothing.
///
/// Removed once the cutover is proven and the legacy tables are gone.
actor ProfileShadowComparator {
    private let databaseReader: any DatabaseReader
    private let profileStore: any ProfileStoreProtocol
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(
        databaseReader: any DatabaseReader,
        profileStore: any ProfileStoreProtocol,
        interval: TimeInterval = 1_800
    ) {
        self.databaseReader = databaseReader
        self.profileStore = profileStore
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        let sleepNanos = UInt64(interval * 1_000_000_000)
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.compareAndLog()
                do {
                    try await Task.sleep(nanoseconds: sleepNanos)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func compareAndLog() async {
        do {
            let result = try await compare()
            if result.hasDiscrepancies {
                Log.warning("ProfileShadowCompare: \(result.summary)")
            } else {
                Log.info("ProfileShadowCompare: no discrepancies across \(result.comparedCount) inboxes")
            }
        } catch {
            Log.error("ProfileShadowCompare failed: \(error.localizedDescription)")
        }
    }

    /// Compares name and avatar-presence for every inbox present in both the new
    /// stores and the legacy `contact` table.
    func compare() async throws -> ProfileShadowComparison {
        let profiles = try await profileStore.allIdentities()
        let avatars = try await profileStore.allAvatars()
        let newAvatarInboxIds = Set(avatars.compactMap { $0.url == nil ? nil : $0.inboxId })

        let contacts = try await databaseReader.read { db in
            try Row.fetchAll(db, sql: "SELECT inboxId, displayName, avatarURL FROM contact")
                .map { row in
                    ContactRow(inboxId: row["inboxId"], displayName: row["displayName"], avatarURL: row["avatarURL"])
                }
        }
        let contactByInbox = Dictionary(contacts.map { ($0.inboxId, $0) }, uniquingKeysWith: { first, _ in first })

        var comparedCount = 0
        var nameMismatches = 0
        var avatarMismatches = 0
        var sampleInboxIds: [String] = []
        for profile in profiles {
            guard let contact = contactByInbox[profile.inboxId] else { continue }
            comparedCount += 1
            let nameDiffers = Self.normalized(profile.name) != Self.normalized(contact.displayName)
            let avatarDiffers = newAvatarInboxIds.contains(profile.inboxId) != (contact.avatarURL != nil)
            if nameDiffers {
                nameMismatches += 1
            }
            if avatarDiffers {
                avatarMismatches += 1
            }
            if nameDiffers || avatarDiffers, sampleInboxIds.count < 5 {
                sampleInboxIds.append(profile.inboxId)
            }
        }
        return ProfileShadowComparison(
            comparedCount: comparedCount,
            nameMismatches: nameMismatches,
            avatarMismatches: avatarMismatches,
            sampleInboxIds: sampleInboxIds
        )
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct ContactRow {
    let inboxId: String
    let displayName: String?
    let avatarURL: String?
}
