import ConvosCore
import Foundation
import Observation

/// Sheet context: the request under review plus the resolved ability
/// (icon, name, and bundle titles come from the catalog entry).
struct AbilityEscalationApprovalContext: Identifiable, Hashable {
    let request: AbilityDelegationRequest
    let ability: AbilitiesAPI.Ability

    var id: String { request.id }
}

/// Drives the conversation consent surfaces: observes the escalation
/// seam's pending-request stream, exposes the single actionable ask, and
/// resolves it through grant or decline. Self-contained: talks only to
/// the latched `AbilitiesSelection`, never to `ConversationViewModel`.
@MainActor @Observable
final class ConversationEscalationViewModel {
    /// The newest pending ask (single-actionable-ask semantics, mirroring
    /// V1's latest-pending-request derivation: older unresolved asks stay
    /// hidden until the newest resolves).
    private(set) var pendingRequest: AbilityDelegationRequest?
    /// The catalog entry backing `pendingRequest`, resolved when the ask
    /// arrives so the prompt card can render the ability's display name.
    private(set) var pendingAbility: AbilitiesAPI.Ability?
    private(set) var isResolving: Bool = false
    private(set) var errorMessage: String?
    /// Non-nil presents the approval sheet.
    var approvalContext: AbilityEscalationApprovalContext?

    private let conversationId: String
    /// The pair latched at construction, same posture as the abilities VMs.
    private let selection: AbilitiesSelection
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(conversationId: String, selection: AbilitiesSelection) {
        self.conversationId = conversationId
        self.selection = selection
    }

    /// Spawns the stream task; idempotent while one is live.
    func startObserving() {
        guard observationTask == nil else { return }
        let escalation = selection.escalation
        let conversationId = conversationId
        observationTask = Task { [weak self] in
            let stream = await escalation.pendingRequestsStream(conversationId: conversationId)
            for await requests in stream {
                guard !Task.isCancelled else { return }
                await self?.handlePendingRequests(requests)
            }
        }
    }

    /// Cancels the stream task (view disappeared). A later
    /// `startObserving` re-subscribes and re-syncs from the first emission.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Resolves the catalog entry for the pending ask and presents the
    /// approval sheet. An unresolvable ability id leaves the card up and
    /// surfaces an error (should not happen with consistent fixtures).
    func presentApproval() {
        guard let request = pendingRequest else { return }
        Task {
            let ability = await resolvedAbility(for: request)
            guard let ability else {
                errorMessage = AbilitiesServiceError.unknownAbility(abilityId: request.abilityId).localizedDescription
                return
            }
            pendingAbility = ability
            approvalContext = AbilityEscalationApprovalContext(request: request, ability: ability)
        }
    }

    func grant(bundleIds: [String], scope: AbilityDelegationScope) {
        resolve { escalation, requestId in
            try await escalation.grant(requestId: requestId, bundleIds: bundleIds, scope: scope)
        }
    }

    func decline() {
        resolve { escalation, requestId in
            try await escalation.decline(requestId: requestId)
        }
    }

    /// Shared resolution path: the service is the source of truth, so the
    /// stream emission (not optimistic local state) is what clears the
    /// card; this only closes the sheet and surfaces failures.
    private func resolve(_ operation: @escaping (any AbilityEscalationServiceProtocol, String) async throws -> Void) {
        guard let request = pendingRequest, !isResolving else { return }
        isResolving = true
        errorMessage = nil
        let escalation = selection.escalation
        Task {
            do {
                try await operation(escalation, request.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isResolving = false
            approvalContext = nil
        }
    }

    private func handlePendingRequests(_ requests: [AbilityDelegationRequest]) async {
        let newest = requests.last
        pendingRequest = newest
        guard let newest else {
            pendingAbility = nil
            return
        }
        if pendingAbility?.id != newest.abilityId {
            pendingAbility = await resolvedAbility(for: newest)
        }
    }

    private func resolvedAbility(for request: AbilityDelegationRequest) async -> AbilitiesAPI.Ability? {
        if let pendingAbility, pendingAbility.id == request.abilityId {
            return pendingAbility
        }
        let catalog = try? await selection.service.fetchCatalog()
        return catalog?.abilities.first { $0.id == request.abilityId }
    }
}
