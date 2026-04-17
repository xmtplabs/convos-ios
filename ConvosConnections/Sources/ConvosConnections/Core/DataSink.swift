import Foundation

/// A destination that executes actions on the user's device in response to agent
/// invocations. The write-side counterpart to `DataSource`.
///
/// A sink for a given `ConnectionKind` may coexist with a `DataSource` of the same kind;
/// they represent opposite directions and do not share state through the protocols.
/// Concrete implementations sometimes share an internal `StateBox` actor, but that's an
/// implementation detail, not a protocol requirement.
public protocol DataSink: Sendable {
    /// The connection this sink writes to.
    var kind: ConnectionKind { get }

    /// Machine-readable schemas for every action this sink supports. Agents use these to
    /// construct valid invocations.
    func actionSchemas() async -> [ActionSchema]

    /// Current authorization status. Uses the same vocabulary as `DataSource` so host UI
    /// can render a single combined status indicator when a kind has both a source and a sink.
    func authorizationStatus() async -> ConnectionAuthorizationStatus

    /// Prompt for authorization if `notDetermined`. Separate from `DataSource.requestAuthorization`
    /// because some frameworks (EventKit) distinguish read-only from read-write auth.
    @discardableResult
    func requestAuthorization() async throws -> ConnectionAuthorizationStatus

    /// Execute an invocation. The sink is responsible for:
    /// - Looking up the action by name
    /// - Validating required arguments against its own schema
    /// - Calling the underlying system API
    /// - Returning a fully-formed `ConnectionInvocationResult`
    ///
    /// The sink must NOT check enablement or always-confirm policy — those are decided by
    /// `ConnectionsManager` before `invoke(_:)` is called. This keeps sinks testable in
    /// isolation and keeps policy in one place.
    func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult

    /// Optional hook for sinks that need long-lived resources.
    func prepare() async throws

    /// Optional teardown.
    func teardown() async
}

public extension DataSink {
    func prepare() async throws {}
    func teardown() async {}
}
