import Foundation

/// A partial edit to the current user's profile. Only the fields explicitly set
/// are changed; `keep` leaves a field as-is. Lets callers update the name
/// without touching metadata, or vice versa, without read-modify-write at the
/// call site.
struct SelfProfileEdit: Sendable {
    enum Field<T: Sendable>: Sendable {
        case keep
        case set(T)
    }

    var name: Field<String?>
    var metadata: Field<ProfileMetadata?>

    init(name: Field<String?> = .keep, metadata: Field<ProfileMetadata?> = .keep) {
        self.name = name
        self.metadata = metadata
    }

    /// Applies the edit to an existing self profile, stamping `updatedAt`.
    func applied(to existing: DBSelfProfile, updatedAt: Date) -> DBSelfProfile {
        var result = existing
        if case let .set(value) = name {
            result.name = value
        }
        if case let .set(value) = metadata {
            result.metadata = value
        }
        result.updatedAt = updatedAt
        return result
    }
}
