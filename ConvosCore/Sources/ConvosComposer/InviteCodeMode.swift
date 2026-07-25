#if canImport(UIKit)
import Foundation

/// Variant of the invite-code screen. Mirrors the `ContactCardMode` pattern:
/// the structure is shared; only caption copy and nav metadata branch on the
/// mode.
public enum InviteCodeMode {
    /// Presented over an existing conversation.
    case inConvo
    /// Presented for a freshly created conversation (no other members yet).
    case newConvo
}

#endif
