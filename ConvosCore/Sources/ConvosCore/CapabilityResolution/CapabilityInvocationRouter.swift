import ConvosConnections
import Foundation

/// Routes a `ConnectionInvocation` (agent → device) to the right execution path based on
/// the per-conversation `CapabilityResolution`.
///
/// Cloud federation is the agent runtime's concern — when the agent has both a device
/// and a cloud provider resolved for a federating-subject read, it sends the device
/// invocation here AND calls Composio directly for the cloud side, then merges the
/// results itself. The iOS device only ever owns its local slice of any federation.
public final class CapabilityInvocationRouter: Sendable {
    public typealias CapabilityLookup = @Sendable (ConnectionInvocation) async -> ConnectionCapability?
    public typealias DeviceDispatch = @Sendable (ConnectionInvocation, String) async -> ConnectionInvocationResult

    private let resolver: any CapabilityResolver
    private let capabilityLookup: CapabilityLookup
    private let deviceDispatch: DeviceDispatch

    public init(
        resolver: any CapabilityResolver,
        capabilityLookup: @escaping CapabilityLookup,
        deviceDispatch: @escaping DeviceDispatch
    ) {
        self.resolver = resolver
        self.capabilityLookup = capabilityLookup
        self.deviceDispatch = deviceDispatch
    }

    public func route(
        _ invocation: ConnectionInvocation,
        conversationId: String
    ) async -> ConnectionInvocationResult {
        guard let subject = DeviceCapabilityProvider.subject(for: invocation.kind) else {
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "ConnectionKind '\(invocation.kind.rawValue)' has no capability subject mapping."
            )
        }

        guard let capability = await capabilityLookup(invocation) else {
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "Action '\(invocation.action.name)' is not declared by any registered sink for kind '\(invocation.kind.rawValue)'."
            )
        }

        let resolution = await resolver.resolution(
            subject: subject,
            capability: capability,
            conversationId: conversationId
        )

        if resolution.isEmpty {
            return Self.makeResult(
                for: invocation,
                status: .capabilityNotEnabled,
                errorMessage: "No resolution for \(subject.rawValue)/\(capability.rawValue) in this conversation. Agents should send a capability_request first."
            )
        }

        let deviceId = DeviceCapabilityProvider.providerId(for: invocation.kind)
        if resolution.contains(deviceId) {
            // Either the resolution is exactly this device provider, or it's a federated
            // read where this device is one of N participants. Either way the device's
            // job is to execute its slice; the agent merges across providers.
            return await deviceDispatch(invocation, conversationId)
        }

        // Resolution exists but doesn't include this device — every member is a cloud
        // provider. The agent should have routed this to Composio directly, not here.
        let providerSummary = resolution.map(\.rawValue).sorted().joined(separator: ", ")
        return Self.makeResult(
            for: invocation,
            status: .executionFailed,
            errorMessage: "Resolution for \(subject.rawValue)/\(capability.rawValue) routes to \(providerSummary); "
                + "call those provider APIs directly rather than sending a device-side ConnectionInvocation."
        )
    }

    private static func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        errorMessage: String? = nil
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            errorMessage: errorMessage
        )
    }
}
