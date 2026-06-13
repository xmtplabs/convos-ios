import Foundation

/// The contract the host app fulfills to route a payload or invocation result to a
/// specific conversation.
///
/// In the Convos app this is implemented by wrapping the payload/result in a custom XMTP
/// content type and sending it. Keeping the protocol here means the package has no XMTP
/// dependency — swapping transports (or mocking in tests) is a one-file change.
public protocol ConnectionDelivering: Sendable {
    /// Deliver `payload` (a source-produced data payload) to `conversationId`.
    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws

    /// Deliver a write-capability invocation result back to the originating conversation.
    ///
    /// Default implementation throws `ConnectionDeliveringError.resultDeliveryUnimplemented`
    /// so existing host adapters that predate the write-capability layer keep compiling.
    /// When an invocation arrives and the host hasn't implemented this method, the manager
    /// records the failure in its recent-invocations log but does not crash.
    func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws
}

/// Errors thrown by the default `ConnectionDelivering` extensions.
public enum ConnectionDeliveringError: Error, Sendable, Equatable {
    case resultDeliveryUnimplemented
}

public extension ConnectionDelivering {
    func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {
        throw ConnectionDeliveringError.resultDeliveryUnimplemented
    }
}

/// Collects delivery outcomes without blocking observation. Useful in the debug view.
public protocol ConnectionDeliveryObserver: Sendable {
    func connectionDelivery(didSucceed payload: ConnectionPayload, conversationId: String) async
    func connectionDelivery(didFail error: Error, payload: ConnectionPayload, conversationId: String) async

    // Invocation delivery — default implementations provided so existing conformers compile.
    func connectionInvocation(didDeliver result: ConnectionInvocationResult, conversationId: String) async
    func connectionInvocation(didFailDelivery error: Error, result: ConnectionInvocationResult, conversationId: String) async
}

public extension ConnectionDeliveryObserver {
    func connectionInvocation(didDeliver result: ConnectionInvocationResult, conversationId: String) async {}
    func connectionInvocation(didFailDelivery error: Error, result: ConnectionInvocationResult, conversationId: String) async {}
}
