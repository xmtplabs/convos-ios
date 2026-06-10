#if canImport(UIKit)
import ConvosCore
import Foundation
import SwiftUI

/// SwiftUI environment carrier for the inbox-to-contact override
/// closure. Each surface that wants contact-authoritative rendering
/// injects the closure once near the top of its view tree, typically
/// `.memberContactOverride(contactsRepository.contact(for:))`.
/// Descendants read `@Environment(\.memberContactOverride)` for richer
/// substitutions (avatar, encrypted image keys, agent verification) or
/// `@Environment(\.memberNameOverride)` for the name-only adapter that
/// ConvosCore APIs (`Conversation.computedDisplayName(memberNameOverride:)`,
/// `ConversationUpdate.summary(memberNameOverride:)`) accept.
///
/// The default is a no-op resolver returning `nil` for every inbox, which
/// preserves the legacy per-conversation profile behavior in previews
/// and any uninjected surface. The lookup itself lives on
/// `ContactsRepositoryProtocol.contact(for:)`.
private struct MemberContactOverrideKey: EnvironmentKey {
    // `@Sendable` because SwiftUI's `EnvironmentKey.defaultValue` is
    // required to be `Sendable` under strict concurrency, and the
    // override is read from many isolation domains (main-actor SwiftUI
    // bodies, background contact fetches).
    static let defaultValue: @Sendable (String) -> Contact? = { _ in nil }
}

public extension EnvironmentValues {
    var memberContactOverride: @Sendable (String) -> Contact? {
        get { self[MemberContactOverrideKey.self] }
        set { self[MemberContactOverrideKey.self] = newValue }
    }

    /// Name-only adapter derived from `memberContactOverride`. Returns
    /// the contact's display name when present and non-empty, otherwise
    /// `nil` so ConvosCore APIs fall back to per-conversation profile
    /// names. Read-only - inject via `.memberContactOverride(_:)` and
    /// this adapter follows automatically.
    var memberNameOverride: @Sendable (String) -> String? {
        let resolver = memberContactOverride
        return { inboxId in
            guard let name = resolver(inboxId)?.displayName, !name.isEmpty else {
                return nil
            }
            return name
        }
    }
}

public extension View {
    /// Injects an inbox-to-contact override closure into the SwiftUI
    /// environment so descendant surfaces (conversation list, pinned
    /// tiles, info previews, system-message cells, ...) substitute the
    /// user's contact data (name and avatar) in place of the
    /// per-conversation profile data.
    func memberContactOverride(_ resolver: @escaping @Sendable (String) -> Contact?) -> some View {
        environment(\.memberContactOverride, resolver)
    }
}
#endif
