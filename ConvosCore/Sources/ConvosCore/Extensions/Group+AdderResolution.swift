import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Persisted discriminator for `DBConversation.adder`. Named after what was
/// observed, not what it implies: `noAdder` is XMTP reporting no adder, which
/// today means a group the local user created.
enum AdderStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case resolved
    case noAdder = "no_adder"
    case unresolved
    case notRecorded = "not_recorded"
}

extension AdderStatus: DatabaseValueConvertible {}

/// Who added the local user to a group.
///
/// `none` and `unresolved` are deliberately distinct: "nobody added us" is a
/// fact we can act on, while "the lookup failed" means we know nothing.
/// Collapsing them lets a failed read pass as a self-created group, which would
/// let a blocked inviter's welcome through on the creator's contact status
/// alone.
enum AdderResolution: Equatable {
    /// The adder is known.
    case known(String)
    /// XMTP reports no adder - a group the local user created.
    case none
    /// The lookup itself failed. We don't know who invited us.
    case unresolved
    /// The row predates the `addedById` column. Adjudicated on the creator
    /// alone, matching the behavior before the column existed; upgraded on the
    /// next write. Never returned by `resolvedAdder()`.
    case notRecorded

    var status: AdderStatus {
        switch self {
        case .known: return .resolved
        case .none: return .noAdder
        case .unresolved: return .unresolved
        case .notRecorded: return .notRecorded
        }
    }

    /// The adder when we actually resolved one, else nil.
    var knownInboxId: String? {
        guard case let .known(inboxId) = self else { return nil }
        return inboxId
    }

    init(status: AdderStatus, addedById: String?) {
        switch status {
        case .resolved: self = addedById.map { .known($0) } ?? .unresolved
        case .noAdder: self = .none
        case .unresolved: self = .unresolved
        case .notRecorded: self = .notRecorded
        }
    }
}

extension XMTPiOS.Group {
    /// Who added the local user to this group.
    ///
    /// `addedByInboxId()` is a local libxmtp read of a NOT NULL column
    /// (`added_by_inbox_id`), so an empty string is the genuine "no adder"
    /// signal and it throws only when the lookup fails. Never rethrows - a
    /// failed read must not sink an inbound welcome - but the failure surfaces
    /// as `unresolved` rather than being silently flattened, so trust decisions
    /// can fail closed.
    func resolvedAdder() -> AdderResolution {
        do {
            let addedByInboxId = try addedByInboxId()
            return addedByInboxId.isEmpty ? .none : .known(addedByInboxId)
        } catch {
            Log.warning(
                "addedByInboxId failed for \(id); treating adder as unresolved: \(error.localizedDescription)"
            )
            return .unresolved
        }
    }
}
