import Combine
import ConvosConnections
import Foundation
import GRDB
import os

/// Session-wide service that fires `AgentBuilder` connection grants once
/// the verified agent has joined a conversation, replaying any grants
/// the in-memory `AgentBuilderViewModel.commit` flow would have lost on
/// app death between Make and agent-join.
///
/// State of the world:
/// - `AgentBuilderViewModel.commit` writes an `AgentBuilderSummary` that
///   carries `.connection` chip attachments (rawValue identifier) plus a
///   `cloudConnectionIds` dictionary mapping the iOS `AgentBuilderConnection`
///   rawValue to the captured `CloudConnection.id` (cloud kinds only —
///   device kinds need no id).
/// - The replayer observes summaries + conversation members. When a
///   summary's conversation gains a verified Convos agent, it walks the
///   connection chips and fires any grant that isn't already applied
///   (idempotency comes from `cloudConnectionRepository.grants(for:)` for
///   cloud kinds and `enablementStore.isEnabled(...)` for device kinds —
///   no separate "did I fire it?" flag is needed).
///
/// Survives app launches because the inputs (summary, members, grant
/// store) all live in the DB.
public final class AgentBuilderConnectionGrantReplayer: Sendable {
    /// `AgentBuilderConnection.appleHealth.rawValue`. Mirrored as a string
    /// constant so the replayer doesn't have to depend on the iOS-side
    /// enum (which only exists in the Convos target).
    private static let appleHealthRawValue: String = "appleHealth"
    /// `AgentBuilderConnection.googleCalendar.rawValue`.
    private static let googleCalendarRawValue: String = "googleCalendar"
    /// Composio service id encoded into the cloud `ProviderID` (i.e.
    /// `composio.googlecalendar`). Mirrors
    /// `AgentBuilderConnection.googleCalendarServiceId`.
    private static let googleCalendarServiceId: String = "googlecalendar"

    private let databaseReader: any DatabaseReader
    private let grantWriter: any CloudConnectionGrantWriterProtocol
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private let connectionEventWriter: any ConnectionEventWriterProtocol
    private let enablementStore: any EnablementStore
    private let summaryWriter: any AgentBuilderSummaryWriterProtocol

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)
    /// Conversations the replayer has already attempted in this process
    /// run. Lets the loop short-circuit redundant work when a stream emit
    /// is identical to the last one (which happens for every unrelated
    /// member edit). Persistent idempotency comes from the summary's
    /// `connectionsAppliedAt` stamp.
    private let inflightConversations: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])

    public init(
        databaseReader: any DatabaseReader,
        grantWriter: any CloudConnectionGrantWriterProtocol,
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        connectionEventWriter: any ConnectionEventWriterProtocol,
        enablementStore: any EnablementStore,
        summaryWriter: any AgentBuilderSummaryWriterProtocol
    ) {
        self.databaseReader = databaseReader
        self.grantWriter = grantWriter
        self.cloudConnectionRepository = cloudConnectionRepository
        self.connectionEventWriter = connectionEventWriter
        self.enablementStore = enablementStore
        self.summaryWriter = summaryWriter
    }

    /// Begin observing. Safe to call repeatedly — the previous task is
    /// cancelled and replaced.
    public func start() {
        let new: Task<Void, Never> = Task { [weak self] in
            await self?.observe()
        }
        observationTask.withLock { existing in
            existing?.cancel()
            existing = new
        }
    }

    public func stop() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }

    private func observe() async {
        let dbReader = databaseReader
        let stream = ValueObservation
            .tracking { db in
                try Self.fetchReadyTargets(db: db)
            }
            .values(in: dbReader)
        do {
            for try await targets in stream {
                if Task.isCancelled { return }
                for target in targets {
                    await tryFireGrants(for: target)
                }
            }
        } catch {
            Log.error("AgentBuilderConnectionGrantReplayer: stream failed: \(error.localizedDescription)")
        }
    }

    private func tryFireGrants(for target: ReplayTarget) async {
        let conversationId: String = target.conversationId
        let claimed: Bool = inflightConversations.withLock { active in
            if active.contains(conversationId) { return false }
            active.insert(conversationId)
            return true
        }
        guard claimed else { return }
        defer {
            inflightConversations.withLock { active in
                active.remove(conversationId)
            }
        }

        let summary: AgentBuilderSummary = target.summary
        let agentInboxIds: [String] = target.agentInboxIds
        guard !agentInboxIds.isEmpty else { return }

        var anyFailed: Bool = false
        for attachment in summary.attachments {
            guard case let .connection(_, identifier) = attachment else { continue }
            switch identifier {
            case Self.appleHealthRawValue:
                let success: Bool = await fireDeviceGrant(
                    kind: .health,
                    conversationId: conversationId,
                    agentInboxIds: agentInboxIds
                )
                if !success { anyFailed = true }
            case Self.googleCalendarRawValue:
                guard let cloudConnectionId = summary.cloudConnectionIds[identifier] else {
                    Log.warning("AgentBuilderConnectionGrantReplayer: missing cloudConnectionId for \(identifier) in \(conversationId) — grant skipped")
                    anyFailed = true
                    continue
                }
                let success: Bool = await fireCloudGrant(
                    connectionId: cloudConnectionId,
                    serviceId: Self.googleCalendarServiceId,
                    conversationId: conversationId,
                    agentInboxIds: agentInboxIds
                )
                if !success { anyFailed = true }
            default:
                // Unknown identifier — newer summaries written by a
                // future build may carry connection kinds this build
                // doesn't recognise. Don't stamp `connectionsAppliedAt`;
                // leave the row eligible for a later build to retry.
                Log.warning("AgentBuilderConnectionGrantReplayer: unknown connection identifier \(identifier) in \(conversationId)")
                anyFailed = true
            }
        }

        guard !anyFailed else { return }
        do {
            try await summaryWriter.markConnectionsApplied(for: conversationId, at: Date())
        } catch {
            Log.error("AgentBuilderConnectionGrantReplayer: markConnectionsApplied failed for \(conversationId): \(error.localizedDescription)")
        }
    }

    /// Returns `true` if every agent in `agentInboxIds` ends the call
    /// with the device kind enabled (either already on disk before we
    /// started, or written successfully now). Per-agent checks make
    /// partial pre-existing state safe: an agent that's missing
    /// enablement still gets written even if a sibling agent already
    /// had it.
    private func fireDeviceGrant(
        kind: ConnectionKind,
        conversationId: String,
        agentInboxIds: [String]
    ) async -> Bool {
        var agentsNeedingWrite: [String] = []
        for agent in agentInboxIds {
            let enabled: Bool = await isAgentCapabilityEnabled(
                kind: kind,
                conversationId: conversationId,
                agent: agent
            )
            if !enabled { agentsNeedingWrite.append(agent) }
        }
        if agentsNeedingWrite.isEmpty { return true }
        var newlyWritten: [String] = []
        for agent in agentsNeedingWrite {
            for capability in ConnectionCapability.allCases {
                await enablementStore.setEnabled(
                    true,
                    kind: kind,
                    capability: capability,
                    conversationId: conversationId,
                    grantedToInboxId: agent
                )
            }
            newlyWritten.append(agent)
        }
        let allEnabled: Bool = newlyWritten.count == agentsNeedingWrite.count
        if let representative = newlyWritten.first {
            do {
                try await connectionEventWriter.sendGranted(
                    providerId: "device.\(kind.rawValue)",
                    capability: nil,
                    grantedToInboxId: representative,
                    in: conversationId
                )
            } catch {
                Log.error("AgentBuilderConnectionGrantReplayer: sendGranted (device \(kind.rawValue)) failed: \(error.localizedDescription)")
                return false
            }
        }
        return allEnabled
    }

    private func fireCloudGrant(
        connectionId: String,
        serviceId: String,
        conversationId: String,
        agentInboxIds: [String]
    ) async -> Bool {
        let alreadyGrantedAgents: Set<String>
        do {
            let grants: [CloudConnectionGrant] = try await cloudConnectionRepository.grants(for: conversationId)
            alreadyGrantedAgents = Set(
                grants
                    .filter { $0.connectionId == connectionId }
                    .map(\.grantedToInboxId)
            )
        } catch {
            Log.error("AgentBuilderConnectionGrantReplayer: grants(for:) failed for \(conversationId): \(error.localizedDescription)")
            return false
        }
        let agentsToGrant: [String] = agentInboxIds.filter { !alreadyGrantedAgents.contains($0) }
        if agentsToGrant.isEmpty { return true }
        let providerId: String = "composio.\(serviceId)"
        var newlyGranted: [String] = []
        for agent in agentsToGrant {
            do {
                try await grantWriter.grantConnection(
                    connectionId,
                    to: conversationId,
                    grantedToInboxId: agent
                )
                newlyGranted.append(agent)
            } catch {
                Log.error("AgentBuilderConnectionGrantReplayer: grantConnection failed for \(serviceId) agent \(agent): \(error.localizedDescription)")
            }
        }
        let allGranted: Bool = newlyGranted.count == agentsToGrant.count
        if let representative = newlyGranted.first {
            do {
                try await connectionEventWriter.sendGranted(
                    providerId: providerId,
                    capability: nil,
                    grantedToInboxId: representative,
                    in: conversationId
                )
            } catch {
                Log.error("AgentBuilderConnectionGrantReplayer: sendGranted (\(providerId)) failed: \(error.localizedDescription)")
                return false
            }
        }
        return allGranted
    }

    private func isAgentCapabilityEnabled(
        kind: ConnectionKind,
        conversationId: String,
        agent: String
    ) async -> Bool {
        for capability in ConnectionCapability.allCases {
            let enabled: Bool = await enablementStore.isEnabled(
                kind: kind,
                capability: capability,
                conversationId: conversationId,
                grantedToInboxId: agent
            )
            if enabled { return true }
        }
        return false
    }

    /// Pull summaries that have at least one `.connection` attachment
    /// joined to conversations that have a verified Convos agent in their
    /// member list. Returned as a flat list of `ReplayTarget`s so the
    /// observation stream is cheap to evaluate (single query, no
    /// per-conversation round-trips).
    private static func fetchReadyTargets(db: Database) throws -> [ReplayTarget] {
        let summaryRows: [DBAgentBuilderSummary] = try DBAgentBuilderSummary.fetchAll(db)
        guard !summaryRows.isEmpty else { return [] }
        var targets: [ReplayTarget] = []
        for row in summaryRows {
            guard row.connectionsAppliedAt == nil else { continue }
            guard let summary = try? row.toAgentBuilderSummary() else { continue }
            guard Self.hasConnectionAttachment(summary) else { continue }
            let agentInboxIds: [String] = try Self.verifiedAgentInboxIds(
                db: db,
                conversationId: row.conversationId
            )
            guard !agentInboxIds.isEmpty else { continue }
            targets.append(ReplayTarget(
                conversationId: row.conversationId,
                summary: summary,
                agentInboxIds: agentInboxIds
            ))
        }
        return targets
    }

    private static func hasConnectionAttachment(_ summary: AgentBuilderSummary) -> Bool {
        summary.attachments.contains { attachment in
            if case .connection = attachment { return true }
            return false
        }
    }

    private static func verifiedAgentInboxIds(db: Database, conversationId: String) throws -> [String] {
        let profileRows: [DBMemberProfile] = try DBMemberProfile
            .filter(DBMemberProfile.Columns.conversationId == conversationId)
            .fetchAll(db)
        return profileRows
            .filter { $0.isAgent && $0.agentVerification.isVerified }
            .map(\.inboxId)
    }
}

private struct ReplayTarget: Sendable {
    let conversationId: String
    let summary: AgentBuilderSummary
    let agentInboxIds: [String]
}
