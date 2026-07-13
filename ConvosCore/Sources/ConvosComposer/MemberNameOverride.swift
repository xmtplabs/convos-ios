#if canImport(UIKit)
import ConvosCore
import Foundation
import SwiftUI

/// SwiftUI environment carrier for the (now deprecated) inbox-to-contact
/// override closure. Identity - display name and image - is sourced
/// authoritatively from the `Profile` database; contact data never overrides
/// it. The resolver is always the no-op returning `nil` for every inbox, so
/// every consumer falls through to the member `Profile`.
///
/// The environment key, the `memberNameOverride` adapter, and the
/// `.memberContactOverride(_:)` modifier are retained (the modifier ignoring
/// its argument) so existing call sites compile until the override plumbing is
/// removed.
private struct MemberContactOverrideKey: EnvironmentKey {
    // `@Sendable` because SwiftUI's `EnvironmentKey.defaultValue` is
    // required to be `Sendable` under strict concurrency, and the
    // resolver is read from many isolation domains (main-actor SwiftUI
    // bodies, background contact fetches).
    static let defaultValue: @Sendable (String) -> Contact? = { _ in nil }
}

public extension EnvironmentValues {
    var memberContactOverride: @Sendable (String) -> Contact? {
        get { self[MemberContactOverrideKey.self] }
        set { self[MemberContactOverrideKey.self] = newValue }
    }

    /// Deprecated no-op name adapter. Always returns `nil` so ConvosCore APIs
    /// source names from the `Profile` database.
    var memberNameOverride: @Sendable (String) -> String? {
        { _ in nil }
    }
}

public extension View {
    /// Deprecated no-op. Contact data no longer overrides `Profile` identity, so
    /// this ignores the resolver and leaves the environment at its `nil` default.
    /// Retained so call sites compile until the plumbing is removed.
    func memberContactOverride(_ resolver: @escaping @Sendable (String) -> Contact?) -> some View {
        self
    }
}
#endif
