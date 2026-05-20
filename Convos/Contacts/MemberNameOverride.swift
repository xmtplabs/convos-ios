import ConvosCore
import Foundation
import SwiftUI

/// SwiftUI environment carrier for the inbox-to-contact-name override
/// closure. Each surface that wants contact-name authoritative rendering
/// injects the closure once near the top of its view tree, typically
/// `.memberNameOverride(contactsRepository.contactName(for:))`.
/// Descendants read `@Environment(\.memberNameOverride)` and forward into
/// ConvosCore APIs like `Conversation.computedDisplayName(memberNameOverride:)`.
///
/// The default is a no-op that returns `nil` for every inbox, which
/// preserves the legacy per-conversation profile name behavior in
/// previews and any uninjected surface. The lookup itself lives on
/// `ContactsRepositoryProtocol.contactName(for:)`.
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
    /// Injects an inbox-to-contact-name override closure into the SwiftUI
    /// environment so descendant rendering surfaces (conversation list,
    /// pinned tiles, info previews, etc.) substitute the user's contact
    /// name in place of the per-conversation profile name.
    func memberNameOverride(_ resolver: @escaping @Sendable (String) -> String?) -> some View {
        environment(\.memberNameOverride, resolver)
    }
}
