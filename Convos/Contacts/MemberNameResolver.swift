import ConvosCore
import Foundation
import SwiftUI

/// Authoritative name source for any inbox the user has added as a
/// contact. When a render site is given this resolver, the contact's
/// stored display name **wins** over the per-conversation profile name
/// — the contact name is the user's deliberate naming choice and should
/// appear consistently across every surface that shows that member
/// (system messages, member rows, chat header, conversation list titles).
///
/// Started as a Phase 2.9 stopgap that only filled in for "Somebody"
/// when the per-conversation profile snapshot hadn't landed yet; now
/// promoted to override semantics so the same person doesn't appear
/// under different names across two conversations they're in. See PRD
/// §Phase 2.9 + §Phase 2.9.1.
///
/// Read-only — looking up a contact for rendering does not auto-add or
/// modify any contact rows.
///
/// `Sendable` so that `resolver.contactName(for:)` produces a `@Sendable
/// (String) -> String?` closure suitable for the `@Environment` value
/// (whose type is `@Sendable`). The wrapped repository protocol is
/// already `Sendable` and the struct only stores it as an immutable `let`.
struct MemberNameResolver: Sendable {
    private let contactsRepository: any ContactsRepositoryProtocol

    init(contactsRepository: any ContactsRepositoryProtocol) {
        self.contactsRepository = contactsRepository
    }

    /// Returns the contact's stored display name for the given inbox, or
    /// `nil` if the inbox is not a known contact or the contact has no
    /// stored name. Callers compose this with the per-conversation profile
    /// name and the "Somebody" sentinel:
    ///
    ///   contactName(inboxId) → profile.name (if non-empty) → "Somebody"
    ///
    /// The full resolution is implemented inside the `formattedNamesString
    /// (memberNameOverride:)`, `ConversationMember.displayName(memberNameOverride:)`,
    /// and `Conversation.computedDisplayName(memberNameOverride:)` overloads —
    /// callers pass `resolver.contactName(for:)` as the override and the
    /// precedence logic stays in ConvosCore.
    func contactName(for inboxId: String) -> String? {
        guard let contact = try? contactsRepository.fetchContact(inboxId: inboxId) else {
            return nil
        }
        guard let stored = contact.displayName, !stored.isEmpty else {
            return nil
        }
        return stored
    }
}

// MARK: - SwiftUI Environment

/// SwiftUI environment carrier for the member-name override closure. Each
/// surface that wants contact-name authoritative rendering injects the
/// resolver once near the top of its view tree
/// (`.memberNameOverride(resolver.contactName(for:))`); descendants read
/// `@Environment(\.memberNameOverride)` and forward into ConvosCore APIs
/// like `Conversation.title(memberNameOverride:)`. The default is a no-op
/// that returns `nil` for every inbox, which preserves the legacy
/// per-conversation profile name behavior in previews and any uninjected
/// surface.
private struct MemberNameOverrideKey: EnvironmentKey {
    // The closure type carries `@Sendable` because SwiftUI's
    // `EnvironmentKey.defaultValue` is required to be `Sendable` under
    // strict concurrency. The override closure is read from many isolation
    // domains (main-actor SwiftUI bodies, background contact fetches), so
    // marking it explicitly captures the intent. ConvosCore APIs that
    // accept `(String) -> String?` accept a `@Sendable` variant
    // automatically (Sendable is the more-constrained subtype).
    static let defaultValue: @Sendable (String) -> String? = { _ in nil }
}

extension EnvironmentValues {
    var memberNameOverride: @Sendable (String) -> String? {
        get { self[MemberNameOverrideKey.self] }
        set { self[MemberNameOverrideKey.self] = newValue }
    }
}

extension View {
    /// Injects an inbox → contact-name override closure into the SwiftUI
    /// environment so descendant rendering surfaces (conversation list,
    /// pinned tiles, info previews, etc.) substitute the user's contact
    /// name in place of the per-conversation profile name.
    func memberNameOverride(_ resolver: @escaping @Sendable (String) -> String?) -> some View {
        environment(\.memberNameOverride, resolver)
    }
}
