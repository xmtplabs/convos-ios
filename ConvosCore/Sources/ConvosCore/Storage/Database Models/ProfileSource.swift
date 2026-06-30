import Foundation

/// Provenance of a stored profile value, used by the merge engine to decide
/// which inbound value wins. Higher precedence always overrides lower; within
/// the same precedence, recency (`updatedAt`) decides. A lower-precedence value
/// only fills a blank left by a higher one.
///
/// Ordering, lowest to highest: `contact` (backfilled from legacy data),
/// `appData` (observed from group app-data), `profileSnapshot` (relayed by the
/// member who added others), `profileUpdate` (authored by the subject).
enum ProfileSource: String, Codable, Hashable, CaseIterable, Comparable {
    case contact
    case appData = "app_data"
    case profileSnapshot = "profile_snapshot"
    case profileUpdate = "profile_update"

    private var precedence: Int {
        switch self {
        case .contact: return 0
        case .appData: return 1
        case .profileSnapshot: return 2
        case .profileUpdate: return 3
        }
    }

    static func < (lhs: ProfileSource, rhs: ProfileSource) -> Bool {
        lhs.precedence < rhs.precedence
    }
}
