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

    /// Applies the edit to an existing self profile, stamping `updatedAt`. Image
    /// fields are carried through untouched (the self accessor also preserves
    /// them on write); only name/metadata are editable here.
    func applied(to existing: DBMyProfile, updatedAt: Date) -> DBMyProfile {
        let newName: String?
        if case let .set(value) = name {
            newName = value
        } else {
            newName = existing.name
        }
        let newMetadata: ProfileMetadata?
        if case let .set(value) = metadata {
            newMetadata = value
        } else {
            newMetadata = existing.metadata
        }
        return DBMyProfile(
            inboxId: existing.inboxId,
            name: newName,
            imageData: existing.imageData,
            imageAssetIdentifier: existing.imageAssetIdentifier,
            imageContentDigest: existing.imageContentDigest,
            metadata: newMetadata,
            updatedAt: updatedAt
        )
    }
}
