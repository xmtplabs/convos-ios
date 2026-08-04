import Foundation

/// In-memory `AbilityEscalationServiceProtocol` driving the consent-flow
/// surfaces until the real transport lands. Simulates the whole request
/// lifecycle: a scripted incoming ask, grant and decline resolution,
/// one-shot consumption, revocation, and derived expiry. Fixture ids match
/// `MockAbilitiesService.standardCatalog()` so icons and names resolve.
public actor MockAbilityEscalationService: AbilityEscalationServiceProtocol {
    /// Seed states for the app, previews, and tests.
    public enum Scenario: Sendable {
        /// Seeded delegations in every display state plus a scripted
        /// incoming calendar request that fires shortly after a
        /// conversation's pending stream is first observed. The default
        /// for the app and for lifecycle previews.
        case scripted
        /// Seeded delegations, no auto-fire (delegations-list previews).
        case populated
        /// Nothing pending, nothing granted (empty states).
        case quiet
    }

    private let scenario: Scenario
    private let artificialDelay: Duration
    private let autoFireDelay: Duration
    private let oneShotConsumptionDelay: Duration
    /// Read at call time so the Debug toggle is live without a relaunch:
    /// when false, every read serves empty, streams emit only the empty
    /// set, and the scripted auto-fire never schedules.
    private let isActive: @Sendable () -> Bool

    private var pendingByConversation: [String: [AbilityDelegationRequest]] = [:]
    private var delegationsById: [String: AbilityDelegation] = [:]
    private var resolvedRequestIds: Set<String> = []
    private var continuationsByConversation: [String: [UUID: AsyncStream<[AbilityDelegationRequest]>.Continuation]] = [:]
    /// The scripted request fires once per conversation per process.
    private var firedConversations: Set<String> = []

    public init(
        scenario: Scenario = .scripted,
        artificialDelay: Duration = .milliseconds(150),
        autoFireDelay: Duration = .seconds(3),
        oneShotConsumptionDelay: Duration = .seconds(8),
        isActive: @escaping @Sendable () -> Bool = { true }
    ) {
        self.scenario = scenario
        self.artificialDelay = artificialDelay
        self.autoFireDelay = autoFireDelay
        self.oneShotConsumptionDelay = oneShotConsumptionDelay
        self.isActive = isActive
        switch scenario {
        case .scripted, .populated:
            for delegation in Self.standardDelegations() {
                delegationsById[delegation.id] = delegation
            }
        case .quiet:
            break
        }
    }

    // MARK: - AbilityEscalationServiceProtocol

    public func pendingRequests(conversationId: String) async -> [AbilityDelegationRequest] {
        await simulateLatency()
        return servedPendingRequests(conversationId: conversationId)
    }

    public func pendingRequestsStream(conversationId: String) async -> AsyncStream<[AbilityDelegationRequest]> {
        let (stream, continuation) = AsyncStream<[AbilityDelegationRequest]>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeContinuation(id: id, conversationId: conversationId)
            }
        }
        continuationsByConversation[conversationId, default: [:]][id] = continuation
        continuation.yield(servedPendingRequests(conversationId: conversationId))
        scheduleAutoFireIfNeeded(conversationId: conversationId)
        return stream
    }

    public func delegations(abilityId: String) async -> [AbilityDelegation] {
        await simulateLatency()
        guard isActive() else { return [] }
        return delegationsById.values
            .filter { (delegation: AbilityDelegation) -> Bool in delegation.abilityId == abilityId }
            .sorted { (lhs: AbilityDelegation, rhs: AbilityDelegation) -> Bool in lhs.grantedAt > rhs.grantedAt }
    }

    @discardableResult
    public func grant(requestId: String, bundleIds: [String], scope: AbilityDelegationScope) async throws -> AbilityDelegation {
        await simulateLatency()
        let request = try takePendingRequest(requestId: requestId)
        let delegation = AbilityDelegation(
            id: "delegation-\(UUID().uuidString)",
            conversationId: request.conversationId,
            conversationName: Self.conversationName(for: request.conversationId),
            agentInboxId: request.agentInboxId,
            agentDisplayName: request.agentDisplayName,
            abilityId: request.abilityId,
            bundleIds: bundleIds,
            scope: scope,
            grantedAt: Date(),
            state: .active
        )
        delegationsById[delegation.id] = delegation
        emitPending(conversationId: request.conversationId)
        if scenario == .scripted, scope == .oneShot {
            scheduleOneShotConsumption(delegationId: delegation.id)
        }
        return delegation
    }

    public func decline(requestId: String) async throws {
        await simulateLatency()
        let request = try takePendingRequest(requestId: requestId)
        emitPending(conversationId: request.conversationId)
    }

    public func revoke(delegationId: String) async throws {
        await simulateLatency()
        guard let delegation = delegationsById[delegationId] else {
            throw AbilityEscalationServiceError.unknownDelegation(delegationId: delegationId)
        }
        guard delegation.state == .active else {
            throw AbilityEscalationServiceError.delegationNotActive(delegationId: delegationId)
        }
        delegationsById[delegationId] = delegation.withState(.revoked)
    }

    // MARK: - Lifecycle helpers

    private func simulateLatency() async {
        guard artificialDelay > .zero else { return }
        try? await Task.sleep(for: artificialDelay)
    }

    private func servedPendingRequests(conversationId: String) -> [AbilityDelegationRequest] {
        guard isActive() else { return [] }
        return pendingByConversation[conversationId] ?? []
    }

    /// Removes and returns the pending request, recording it as resolved.
    /// A second resolution throws `requestAlreadyResolved`; an id that was
    /// never pending throws `unknownRequest`.
    private func takePendingRequest(requestId: String) throws -> AbilityDelegationRequest {
        guard !resolvedRequestIds.contains(requestId) else {
            throw AbilityEscalationServiceError.requestAlreadyResolved(requestId: requestId)
        }
        for (conversationId, requests) in pendingByConversation {
            guard let request = requests.first(where: { $0.id == requestId }) else { continue }
            pendingByConversation[conversationId] = requests.filter { $0.id != requestId }
            resolvedRequestIds.insert(requestId)
            return request
        }
        throw AbilityEscalationServiceError.unknownRequest(requestId: requestId)
    }

    private func emitPending(conversationId: String) {
        let served: [AbilityDelegationRequest] = servedPendingRequests(conversationId: conversationId)
        for continuation in (continuationsByConversation[conversationId] ?? [:]).values {
            continuation.yield(served)
        }
    }

    private func removeContinuation(id: UUID, conversationId: String) {
        continuationsByConversation[conversationId]?.removeValue(forKey: id)
    }

    private func scheduleAutoFireIfNeeded(conversationId: String) {
        guard scenario == .scripted, isActive(), !firedConversations.contains(conversationId) else { return }
        firedConversations.insert(conversationId)
        Task { [autoFireDelay] in
            try? await Task.sleep(for: autoFireDelay)
            await self.fireScriptedRequest(conversationId: conversationId)
        }
    }

    private func fireScriptedRequest(conversationId: String) {
        guard isActive() else { return }
        let request = Self.scriptedRequest(conversationId: conversationId)
        pendingByConversation[conversationId, default: []].append(request)
        emitPending(conversationId: conversationId)
    }

    /// Simulates the agent using its single shot: the granted one-shot
    /// delegation flips to consumed after the consumption delay.
    private func scheduleOneShotConsumption(delegationId: String) {
        Task { [oneShotConsumptionDelay] in
            try? await Task.sleep(for: oneShotConsumptionDelay)
            await self.consumeOneShot(delegationId: delegationId)
        }
    }

    private func consumeOneShot(delegationId: String) {
        guard let delegation = delegationsById[delegationId], delegation.state == .active else { return }
        delegationsById[delegationId] = delegation.withState(.consumed)
    }

    // MARK: - Fixtures

    /// The scripted incoming ask: Caley wants Google Calendar in whatever
    /// conversation first observes the pending stream. Asks for both
    /// calendar bundles so the approval sheet's narrowing interaction is
    /// exercisable (a single-bundle ask could only be granted whole or
    /// not at all).
    public static func scriptedRequest(conversationId: String, requestedAt: Date = Date()) -> AbilityDelegationRequest {
        AbilityDelegationRequest(
            id: "request-scripted-\(conversationId)",
            conversationId: conversationId,
            agentInboxId: Constant.mockAgentInboxId,
            agentDisplayName: Constant.mockAgentDisplayName,
            abilityId: "googlecalendar",
            requestedBundleIds: ["calendar.events", "calendar.availability"],
            reason: "Alex asked me to add the team dinner to your calendar.",
            requestedAt: requestedAt
        )
    }

    /// Seeded delegations covering every display state, consistent with
    /// `MockAbilitiesService.standardCatalog()` ability and bundle ids.
    /// The gmail entry is stored active with a past expiry, proving the
    /// derived-expiry read end to end.
    public static func standardDelegations(now: Date = Date()) -> [AbilityDelegation] {
        [
            AbilityDelegation(
                id: "delegation-gcal-active",
                conversationId: Constant.mockConversationOneId,
                conversationName: Constant.mockConversationOneName,
                agentInboxId: Constant.mockAgentInboxId,
                agentDisplayName: Constant.mockAgentDisplayName,
                abilityId: "googlecalendar",
                bundleIds: ["calendar.events"],
                scope: .expiring(now.addingTimeInterval(Constant.sixDays)),
                grantedAt: now.addingTimeInterval(-Constant.oneDay),
                state: .active
            ),
            AbilityDelegation(
                id: "delegation-gcal-consumed",
                conversationId: Constant.mockConversationTwoId,
                conversationName: Constant.mockConversationTwoName,
                agentInboxId: Constant.mockAgentInboxId,
                agentDisplayName: Constant.mockAgentDisplayName,
                abilityId: "googlecalendar",
                bundleIds: ["calendar.events", "calendar.availability"],
                scope: .oneShot,
                grantedAt: now.addingTimeInterval(-Constant.twoDays),
                state: .consumed
            ),
            AbilityDelegation(
                id: "delegation-gmail-expired",
                conversationId: Constant.mockConversationOneId,
                conversationName: Constant.mockConversationOneName,
                agentInboxId: Constant.mockAgentInboxId,
                agentDisplayName: Constant.mockAgentDisplayName,
                abilityId: "gmail",
                bundleIds: ["gmail.read"],
                scope: .expiring(now.addingTimeInterval(-Constant.twoDays)),
                grantedAt: now.addingTimeInterval(-Constant.nineDays),
                state: .active
            ),
            AbilityDelegation(
                id: "delegation-coinbase-revoked",
                conversationId: Constant.mockConversationOneId,
                conversationName: Constant.mockConversationOneName,
                agentInboxId: Constant.mockAgentInboxId,
                agentDisplayName: Constant.mockAgentDisplayName,
                abilityId: "coinbase",
                bundleIds: ["coinbase.prices"],
                scope: .expiring(now.addingTimeInterval(Constant.threeDays)),
                grantedAt: now.addingTimeInterval(-Constant.threeDays),
                state: .revoked
            ),
        ]
    }

    /// Display label for a delegation's conversation: fixture names for
    /// the mock conversations, a neutral label for real conversation ids
    /// the mock cannot resolve.
    private static func conversationName(for conversationId: String) -> String {
        switch conversationId {
        case Constant.mockConversationOneId: Constant.mockConversationOneName
        case Constant.mockConversationTwoId: Constant.mockConversationTwoName
        default: "This convo"
        }
    }

    private enum Constant {
        static let mockConversationOneId: String = "mock-conversation-1"
        static let mockConversationTwoId: String = "mock-conversation-2"
        static let mockConversationOneName: String = "Weekend planning"
        static let mockConversationTwoName: String = "Family"
        static let mockAgentInboxId: String = "mock-agent-inbox-1"
        static let mockAgentDisplayName: String = "Caley"
        static let oneDay: TimeInterval = 86_400
        static let twoDays: TimeInterval = 172_800
        static let threeDays: TimeInterval = 259_200
        static let sixDays: TimeInterval = 518_400
        static let nineDays: TimeInterval = 777_600
    }
}
