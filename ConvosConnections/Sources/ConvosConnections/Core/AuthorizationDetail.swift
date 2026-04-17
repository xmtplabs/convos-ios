import Foundation

/// Per-type authorization detail exposed by a data source.
///
/// Purpose: let the host app show the user *which specific permissions* were asked for and
/// what the system returned, when that granularity matters. HealthKit is the driving case
/// (many sample types, user granted them individually) but the shape works for any source
/// that subdivides its permission scope.
///
/// ## Why not just use `ConnectionAuthorizationStatus` directly?
///
/// For some frameworks — notably HealthKit's read-only sample types — iOS deliberately
/// does not disclose the per-type grant outcome to the app. In those cases `status` can
/// only distinguish "we asked" from "we haven't asked yet." The `note` field carries a
/// short user-facing explanation of that limitation so the UI can show the caveat without
/// misleading the user into thinking the source has precise knowledge.
public struct AuthorizationDetail: Sendable, Hashable, Identifiable {
    /// Stable identifier for the sub-type. Source-specific (e.g. `"stepCount"`,
    /// `"workout"`, `"event"`). Treated as opaque by the host app.
    public let identifier: String

    /// Short human-readable name for the UI row. Does not need to be localized by the
    /// package — the host app can map identifiers to localized strings if needed.
    public let displayName: String

    /// The system's view of whether this sub-type is authorized. For read-only types where
    /// the system hides the outcome, `.authorized` means "the user made a decision" rather
    /// than "we have access" — pair it with `note` to convey that.
    public let status: ConnectionAuthorizationStatus

    /// Optional short note surfaced next to the row. Use it to explain imprecision or
    /// caveats (e.g. "Actual read grant is hidden by iOS for privacy").
    public let note: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        displayName: String,
        status: ConnectionAuthorizationStatus,
        note: String? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.status = status
        self.note = note
    }
}
