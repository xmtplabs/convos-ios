import Foundation

/// A specific action dimension a connection can authorize, orthogonal to its `ConnectionKind`.
///
/// A user can grant `.read` without any write capability, or mix and match write capabilities.
/// The raw value is the persisted discriminator; changing it is a breaking change to any
/// durable `EnablementStore` backing.
public enum ConnectionCapability: String, Codable, Sendable, CaseIterable, Hashable {
    case read
    case writeCreate = "write_create"
    case writeUpdate = "write_update"
    case writeDelete = "write_delete"
}

public extension ConnectionCapability {
    /// True for every capability except `.read`.
    var isWrite: Bool {
        switch self {
        case .read: return false
        case .writeCreate, .writeUpdate, .writeDelete: return true
        }
    }

    var displayName: String {
        switch self {
        case .read: return "Read"
        case .writeCreate: return "Create"
        case .writeUpdate: return "Update"
        case .writeDelete: return "Delete"
        }
    }
}
