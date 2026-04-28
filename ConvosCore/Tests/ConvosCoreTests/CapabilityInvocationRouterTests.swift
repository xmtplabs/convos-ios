@testable import ConvosCore
import ConvosConnections
import Foundation
import Testing

@Suite("CapabilityInvocationRouter")
struct CapabilityInvocationRouterTests {
    private let conversationId: String = "conv-1"

    private func makeInvocation(
        kind: ConnectionKind = .calendar,
        actionName: String = "create_event"
    ) -> ConnectionInvocation {
        ConnectionInvocation(
            invocationId: "inv-1",
            kind: kind,
            action: ConnectionAction(name: actionName, arguments: [:])
        )
    }

    private actor DeviceDispatchSpy {
        private(set) var calls: [String] = []
        func record(_ actionName: String) {
            calls.append(actionName)
        }
    }

    private func makeRouter(
        resolver: any CapabilityResolver,
        capabilityFor: [String: ConnectionCapability] = [:],
        spy: DeviceDispatchSpy
    ) -> CapabilityInvocationRouter {
        CapabilityInvocationRouter(
            resolver: resolver,
            capabilityLookup: { invocation in
                capabilityFor[invocation.action.name]
            },
            deviceDispatch: { invocation, _ in
                await spy.record(invocation.action.name)
                return ConnectionInvocationResult(
                    invocationId: invocation.invocationId,
                    kind: invocation.kind,
                    actionName: invocation.action.name,
                    status: .success
                )
            }
        )
    }

    @Test("unknown kind returns unknownAction without dispatching")
    func unknownKind() async {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        let spy = DeviceDispatchSpy()
        let router = makeRouter(resolver: resolver, spy: spy)
        let result = await router.route(makeInvocation(kind: .motion), conversationId: conversationId)
        #expect(result.status == .unknownAction)
        let calls = await spy.calls
        #expect(calls.isEmpty)
    }

    @Test("unknown action name returns unknownAction without dispatching")
    func unknownAction() async {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        let spy = DeviceDispatchSpy()
        let router = makeRouter(resolver: resolver, capabilityFor: [:], spy: spy)
        let result = await router.route(makeInvocation(actionName: "fictional_action"), conversationId: conversationId)
        #expect(result.status == .unknownAction)
        let calls = await spy.calls
        #expect(calls.isEmpty)
    }

    @Test("empty resolution returns capabilityNotEnabled")
    func capabilityNotEnabledOnEmpty() async {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        let spy = DeviceDispatchSpy()
        let router = makeRouter(
            resolver: resolver,
            capabilityFor: ["create_event": .writeCreate],
            spy: spy
        )
        let result = await router.route(makeInvocation(actionName: "create_event"), conversationId: conversationId)
        #expect(result.status == .capabilityNotEnabled)
        let calls = await spy.calls
        #expect(calls.isEmpty)
    }

    @Test("resolution to device provider dispatches to deviceDispatch")
    func dispatchesToDevice() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [DeviceCapabilityProvider.providerId(for: .calendar)],
            subject: .calendar,
            capability: .writeCreate,
            conversationId: conversationId
        )
        let spy = DeviceDispatchSpy()
        let router = makeRouter(
            resolver: resolver,
            capabilityFor: ["create_event": .writeCreate],
            spy: spy
        )
        let result = await router.route(makeInvocation(actionName: "create_event"), conversationId: conversationId)
        #expect(result.status == .success)
        let calls = await spy.calls
        #expect(calls == ["create_event"])
    }

    @Test("federated read with device provider in the set still dispatches to device")
    func federatedDeviceSlice() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [
                DeviceCapabilityProvider.providerId(for: .health),
                ProviderID(rawValue: "composio.strava"),
            ],
            subject: .fitness,
            capability: .read,
            conversationId: conversationId
        )
        let spy = DeviceDispatchSpy()
        let router = makeRouter(
            resolver: resolver,
            capabilityFor: ["list_recent_workouts": .read],
            spy: spy
        )
        let result = await router.route(
            makeInvocation(kind: .health, actionName: "list_recent_workouts"),
            conversationId: conversationId
        )
        #expect(result.status == .success)
        let calls = await spy.calls
        #expect(calls == ["list_recent_workouts"])
    }

    @Test("cloud-only resolution returns executionFailed with provider hint")
    func cloudOnlyExecutionFailed() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [ProviderID(rawValue: "composio.google_calendar")],
            subject: .calendar,
            capability: .writeCreate,
            conversationId: conversationId
        )
        let spy = DeviceDispatchSpy()
        let router = makeRouter(
            resolver: resolver,
            capabilityFor: ["create_event": .writeCreate],
            spy: spy
        )
        let result = await router.route(makeInvocation(actionName: "create_event"), conversationId: conversationId)
        #expect(result.status == .executionFailed)
        #expect(result.errorMessage?.contains("composio.google_calendar") == true)
        let calls = await spy.calls
        #expect(calls.isEmpty, "device dispatch should not run when the resolution is cloud-only")
    }

    @Test("federated read with only cloud providers returns executionFailed")
    func federatedCloudOnly() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [
                ProviderID(rawValue: "composio.strava"),
                ProviderID(rawValue: "composio.fitbit"),
            ],
            subject: .fitness,
            capability: .read,
            conversationId: conversationId
        )
        let spy = DeviceDispatchSpy()
        let router = makeRouter(
            resolver: resolver,
            capabilityFor: ["list_recent_workouts": .read],
            spy: spy
        )
        let result = await router.route(
            makeInvocation(kind: .health, actionName: "list_recent_workouts"),
            conversationId: conversationId
        )
        #expect(result.status == .executionFailed)
        let calls = await spy.calls
        #expect(calls.isEmpty)
    }

    @Test("conversation scoping — resolution in conv A doesn't satisfy conv B")
    func conversationScoped() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [DeviceCapabilityProvider.providerId(for: .calendar)],
            subject: .calendar,
            capability: .writeCreate,
            conversationId: "conv-a"
        )
        let spy = DeviceDispatchSpy()
        let router = makeRouter(
            resolver: resolver,
            capabilityFor: ["create_event": .writeCreate],
            spy: spy
        )
        let result = await router.route(makeInvocation(actionName: "create_event"), conversationId: "conv-b")
        #expect(result.status == .capabilityNotEnabled)
        let calls = await spy.calls
        #expect(calls.isEmpty)
    }
}
