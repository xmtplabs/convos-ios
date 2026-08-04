@testable import ConvosCore
import Foundation
import Testing

/// Mutable flag captured by the mock's `isActive` closure; tests flip it
/// mid-run to prove the gate is read at call time. Reads and writes are
/// sequenced by the test body itself.
private final class ActiveFlagBox: @unchecked Sendable {
    var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }
}

@Suite("MockAbilityEscalationService")
struct AbilityEscalationMockTests {
    private func makeService(
        scenario: MockAbilityEscalationService.Scenario = .scripted,
        isActive: @escaping @Sendable () -> Bool = { true }
    ) -> MockAbilityEscalationService {
        MockAbilityEscalationService(
            scenario: scenario,
            artificialDelay: .zero,
            autoFireDelay: .milliseconds(10),
            oneShotConsumptionDelay: .milliseconds(10),
            isActive: isActive
        )
    }

    /// Waits for the scripted request through a fresh stream: first
    /// emission is the current (empty) set, the next carries the ask.
    private func awaitScriptedRequest(
        from service: MockAbilityEscalationService,
        conversationId: String
    ) async throws -> (request: AbilityDelegationRequest, iterator: AsyncStream<[AbilityDelegationRequest]>.AsyncIterator) {
        let stream = await service.pendingRequestsStream(conversationId: conversationId)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == [])
        let second = await iterator.next()
        let request = try #require(second?.last)
        return (request, iterator)
    }

    @Test("Scripted stream emits current state, then the scripted request with catalog-consistent ids")
    func scriptedStreamLifecycle() async throws {
        let service = makeService()
        let (request, _) = try await awaitScriptedRequest(from: service, conversationId: "convo-a")

        let catalog = MockAbilitiesService.standardCatalog()
        let ability = try #require(catalog.first { $0.id == request.abilityId })
        #expect(request.agentInboxId == "mock-agent-inbox-1")
        let bundleIds = Set(ability.bundles.map(\.id))
        #expect(Set(request.requestedBundleIds).isSubset(of: bundleIds))
        #expect(!request.requestedBundleIds.isEmpty)
        #expect(!request.reason.isEmpty)
    }

    @Test("Grant empties the pending set, returns an active delegation, and lists it")
    func grantResolvesRequest() async throws {
        let service = makeService()
        let arrival = try await awaitScriptedRequest(from: service, conversationId: "convo-b")
        let request = arrival.request
        var iterator = arrival.iterator

        let scope = AbilityDelegationScope.oneShot
        let delegation = try await service.grant(requestId: request.id, bundleIds: ["calendar.events"], scope: scope)
        #expect(delegation.state == .active)
        #expect(delegation.bundleIds == ["calendar.events"])
        #expect(delegation.scope == scope)
        #expect(delegation.conversationId == "convo-b")

        let afterGrant = await iterator.next()
        #expect(afterGrant == [])

        let listed = await service.delegations(abilityId: request.abilityId)
        #expect(listed.contains { $0.id == delegation.id })
    }

    @Test("Second resolution throws requestAlreadyResolved; unknown ids throw unknownRequest")
    func grantIdempotency() async throws {
        let service = makeService()
        let (request, _) = try await awaitScriptedRequest(from: service, conversationId: "convo-c")

        try await service.grant(requestId: request.id, bundleIds: ["calendar.events"], scope: .oneShot)

        await #expect(throws: AbilityEscalationServiceError.requestAlreadyResolved(requestId: request.id)) {
            try await service.grant(requestId: request.id, bundleIds: ["calendar.events"], scope: .oneShot)
        }
        await #expect(throws: AbilityEscalationServiceError.requestAlreadyResolved(requestId: request.id)) {
            try await service.decline(requestId: request.id)
        }
        await #expect(throws: AbilityEscalationServiceError.unknownRequest(requestId: "nope")) {
            try await service.grant(requestId: "nope", bundleIds: [], scope: .oneShot)
        }
    }

    @Test("Decline empties the pending set and creates no delegation")
    func declineCreatesNothing() async throws {
        let service = makeService()
        let arrival = try await awaitScriptedRequest(from: service, conversationId: "convo-d")
        let request = arrival.request
        var iterator = arrival.iterator

        let before = await service.delegations(abilityId: request.abilityId)
        try await service.decline(requestId: request.id)
        let afterDecline = await iterator.next()
        #expect(afterDecline == [])
        let after = await service.delegations(abilityId: request.abilityId)
        #expect(after == before)
    }

    @Test("Revoke flips active to revoked; repeat and unknown ids throw")
    func revokeLifecycle() async throws {
        let service = makeService(scenario: .populated)
        let activeId = "delegation-gcal-active"

        try await service.revoke(delegationId: activeId)
        let listed = await service.delegations(abilityId: "googlecalendar")
        let revoked = try #require(listed.first { $0.id == activeId })
        #expect(revoked.state == .revoked)

        await #expect(throws: AbilityEscalationServiceError.delegationNotActive(delegationId: activeId)) {
            try await service.revoke(delegationId: activeId)
        }
        await #expect(throws: AbilityEscalationServiceError.unknownDelegation(delegationId: "nope")) {
            try await service.revoke(delegationId: "nope")
        }
    }

    @Test("A granted one-shot flips to consumed after the consumption delay")
    func oneShotConsumption() async throws {
        let service = makeService()
        let (request, _) = try await awaitScriptedRequest(from: service, conversationId: "convo-e")
        let delegation = try await service.grant(requestId: request.id, bundleIds: ["calendar.events"], scope: .oneShot)

        var consumed = false
        for _ in 0..<200 where !consumed {
            let listed = await service.delegations(abilityId: request.abilityId)
            if listed.first(where: { $0.id == delegation.id })?.state == .consumed {
                consumed = true
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(consumed)
    }

    @Test("Expiry is derived from scope, never stored; revoked wins over past expiry")
    func expiryDerivation() {
        let now = Date()
        let seeds = MockAbilityEscalationService.standardDelegations(now: now)
        let expired = seeds.first { $0.id == "delegation-gmail-expired" }
        #expect(expired?.state == .active)
        #expect(expired?.effectiveState(at: now) == .expired)

        let active = seeds.first { $0.id == "delegation-gcal-active" }
        #expect(active?.effectiveState(at: now) == .active)

        let revokedPastExpiry = AbilityDelegation(
            id: "delegation-test-revoked",
            conversationId: "c",
            conversationName: "C",
            agentInboxId: "a",
            agentDisplayName: "A",
            abilityId: "gmail",
            bundleIds: ["gmail.read"],
            scope: .expiring(now.addingTimeInterval(-60)),
            grantedAt: now.addingTimeInterval(-120),
            state: .revoked
        )
        #expect(revokedPastExpiry.effectiveState(at: now) == .revoked)
    }

    @Test("isActive gate: reads serve empty, auto-fire never lands, and the closure is read at call time")
    func inactiveGate() async throws {
        let flag = ActiveFlagBox(isActive: false)
        let service = makeService(isActive: { flag.isActive })

        let pending = await service.pendingRequests(conversationId: "convo-f")
        #expect(pending.isEmpty)
        let seeded = await service.delegations(abilityId: "googlecalendar")
        #expect(seeded.isEmpty)

        let stream = await service.pendingRequestsStream(conversationId: "convo-f")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == [])

        // Well past the 10ms auto-fire delay: nothing may have landed.
        try await Task.sleep(for: .milliseconds(100))
        let stillPending = await service.pendingRequests(conversationId: "convo-f")
        #expect(stillPending.isEmpty)

        // Flipping the captured flag makes the very next call serve.
        flag.isActive = true
        let served = await service.delegations(abilityId: "googlecalendar")
        #expect(!served.isEmpty)

        // A fresh subscription now schedules the scripted fire.
        let (request, _) = try await awaitScriptedRequest(from: service, conversationId: "convo-f")
        #expect(request.abilityId == "googlecalendar")
    }

    @Test("Seeded fixtures: unique ids, catalog-resolvable abilities, all four display states")
    func fixtureSanity() {
        let now = Date()
        let seeds = MockAbilityEscalationService.standardDelegations(now: now)
        let ids = seeds.map(\.id)
        #expect(Set(ids).count == ids.count)

        let catalog = MockAbilitiesService.standardCatalog()
        let catalogIds = Set(catalog.map(\.id))
        for seed in seeds {
            #expect(catalogIds.contains(seed.abilityId))
            let ability = catalog.first { $0.id == seed.abilityId }
            let bundleIds = Set(ability?.bundles.map(\.id) ?? [])
            #expect(Set(seed.bundleIds).isSubset(of: bundleIds))
        }

        let displayStates = Set(seeds.map { $0.effectiveState(at: now) })
        #expect(displayStates == [.active, .consumed, .expired, .revoked])
    }
}
