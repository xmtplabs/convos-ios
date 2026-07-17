import Foundation

/// Closure used by a `DataSource` to emit a payload to the manager.
public typealias ConnectionPayloadEmitter = @Sendable (ConnectionPayload) -> Void

/// A source of data that can be observed and surfaced to the user's conversations.
///
/// Implementations own the native-framework-specific details (HealthKit observer queries,
/// EventKit change notifications, Core Location updates, etc.) and translate them into
/// `ConnectionPayload` values via the `emit` closure supplied to `start(emit:)`.
///
/// Implementations should be safe to call from any isolation context. Conformers are
/// typically `actor` types.
public protocol DataSource: Sendable {
    /// The connection this source represents. Stable across a single process's lifetime.
    var kind: ConnectionKind { get }

    /// Current authorization status. Should be cheap and non-blocking — cache internally
    /// if the underlying API is slow.
    func authorizationStatus() async -> ConnectionAuthorizationStatus

    /// Prompt the user for authorization if `notDetermined`; otherwise return the current status.
    /// Throws if the system call fails.
    @discardableResult
    func requestAuthorization() async throws -> ConnectionAuthorizationStatus

    /// Per-type authorization breakdown.
    ///
    /// Sources that span multiple sub-types (HealthKit's many sample types, future Location
    /// precision levels, etc.) return one entry per type. Sources with a single authorization
    /// scope return an empty array — the top-level `authorizationStatus()` is the only
    /// relevant signal in that case.
    ///
    /// Default implementation returns `[]`.
    func authorizationDetails() async -> [AuthorizationDetail]

    /// Begin observing the source. The source calls `emit` on its own isolation context
    /// whenever a new payload is available. Calling `start` while already started is a no-op.
    func start(emit: @escaping ConnectionPayloadEmitter) async throws

    /// Stop observing. Safe to call when not started.
    func stop() async
}

public extension DataSource {
    func authorizationDetails() async -> [AuthorizationDetail] { [] }
}
