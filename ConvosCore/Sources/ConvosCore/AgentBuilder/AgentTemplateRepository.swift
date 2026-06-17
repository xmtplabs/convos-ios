import Combine
import Foundation
import GRDB
import os

/// UI-facing snapshot of an agent-template generation. Hydrated from
/// `DBAgentTemplateGeneration` and published per conversation so the pending
/// builder UI can react to lifecycle transitions.
public struct AgentTemplateGeneration: Sendable, Equatable {
    public enum Status: String, Sendable {
        case submitting
        case pending
        case running
        case done
        case invited
        case failed
    }

    public let conversationId: String
    public let status: Status
    public let templateId: String?
    public let errorMessage: String?
    /// In-progress draft identity (PR #309); `nil` until the first preview.
    public let preview: ConvosAPI.AgentPreview?
    /// In-progress build-narration lines (PR #309); `[]` when none.
    public let progressPhrases: [String]

    public init(
        conversationId: String,
        status: Status,
        templateId: String?,
        errorMessage: String?,
        preview: ConvosAPI.AgentPreview? = nil,
        progressPhrases: [String] = []
    ) {
        self.conversationId = conversationId
        self.status = status
        self.templateId = templateId
        self.errorMessage = errorMessage
        self.preview = preview
        self.progressPhrases = progressPhrases
    }
}

/// Performs the agent-join for a finished template. Routed through
/// `SessionManager.addAgentToConversation` (not the raw API client) so the
/// direct-add provision/add runs and the agent is added to the conversation
/// the build targeted.
public typealias AgentTemplateJoinHandler = @Sendable (_ conversationId: String, _ templateId: String) async throws -> Void

public protocol AgentTemplateRepositoryProtocol: Sendable {
    /// Kicks off a text-only generation for `conversationId`. Persists the row
    /// first, then drives submit -> poll -> invite in the background. Safe to
    /// call once per build; the persisted row makes it idempotent across
    /// relaunch.
    func startGeneration(prompt: String, conversationId: String, slug: String)

    /// Latest generation for a conversation, observed reactively.
    func generationPublisher(conversationId: String) -> AnyPublisher<AgentTemplateGeneration?, Never>

    /// Re-drives any non-terminal rows after an app relaunch.
    func resumePendingGenerations()

    /// Inject the session-routed join (set once at session init). When set,
    /// the invite step uses it instead of the raw API client so the join
    /// polling runs.
    func configureJoinHandler(_ handler: @escaping AgentTemplateJoinHandler)
}

/// Owns the direct agent-builder generation lifecycle: submit the prompt to
/// `POST /v2/agent-templates/generations`, poll until terminal, then invite
/// the resulting template into the conversation. Session-scoped so the poll
/// loop survives the builder sheet being dismissed; all state is persisted to
/// `DBAgentTemplateGeneration` so it also survives app restart.
public final class AgentTemplateRepository: AgentTemplateRepositoryProtocol {
    private let apiClient: any ConvosAPIClientProtocol
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let source: String
    private let clientDeviceId: String?

    /// Idempotency keys with a pipeline already running in this process, so a
    /// duplicate `startGeneration` / `resume` can't double-drive one row.
    private let inflight: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])

    /// Session-routed join, injected at session init. Falls back to the raw
    /// API client when unset (e.g. in tests).
    private let joinHandler: OSAllocatedUnfairLock<AgentTemplateJoinHandler?> = .init(initialState: nil)

    public init(
        apiClient: any ConvosAPIClientProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        source: String,
        clientDeviceId: String?
    ) {
        self.apiClient = apiClient
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.source = source
        self.clientDeviceId = clientDeviceId
    }

    // MARK: - Public

    public func configureJoinHandler(_ handler: @escaping AgentTemplateJoinHandler) {
        joinHandler.withLock { $0 = handler }
    }

    public func startGeneration(prompt: String, conversationId: String, slug: String) {
        let idempotencyKey: String = UUID().uuidString
        let now: Date = Date()
        let row = DBAgentTemplateGeneration(
            idempotencyKey: idempotencyKey,
            generationId: nil,
            conversationId: conversationId,
            slug: slug,
            status: .submitting,
            templateId: nil,
            prompt: prompt,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.databaseWriter.write { db in
                    try row.insert(db)
                }
            } catch {
                Log.error("AgentTemplateRepository: failed to persist generation row: \(error.localizedDescription)")
                return
            }
            await self.drive(idempotencyKey: idempotencyKey)
        }
    }

    public func generationPublisher(conversationId: String) -> AnyPublisher<AgentTemplateGeneration?, Never> {
        ValueObservation
            .tracking { db in
                try DBAgentTemplateGeneration
                    .filter(DBAgentTemplateGeneration.Columns.conversationId == conversationId)
                    .order(DBAgentTemplateGeneration.Columns.createdAt.desc)
                    .fetchOne(db)
            }
            .publisher(in: databaseReader)
            .map { record -> AgentTemplateGeneration? in
                guard let record else { return nil }
                return AgentTemplateGeneration(
                    conversationId: record.conversationId,
                    status: AgentTemplateGeneration.Status(rawValue: record.status) ?? .pending,
                    templateId: record.templateId,
                    errorMessage: record.errorMessage,
                    preview: Self.preview(from: record),
                    progressPhrases: Self.decodePhrases(record.progressPhrases)
                )
            }
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    private static func preview(from record: DBAgentTemplateGeneration) -> ConvosAPI.AgentPreview? {
        guard record.previewAgentName != nil || record.previewEmoji != nil || record.previewDescription != nil else {
            return nil
        }
        return ConvosAPI.AgentPreview(
            agentName: record.previewAgentName,
            emoji: record.previewEmoji,
            description: record.previewDescription
        )
    }

    public func resumePendingGenerations() {
        Task { [weak self] in
            guard let self else { return }
            let keys: [String]
            do {
                keys = try await self.databaseReader.read { db in
                    try DBAgentTemplateGeneration
                        .filter(!Self.terminalStatuses.contains(DBAgentTemplateGeneration.Columns.status))
                        .fetchAll(db)
                        .map(\.idempotencyKey)
                }
            } catch {
                Log.error("AgentTemplateRepository: resume query failed: \(error.localizedDescription)")
                return
            }
            for key in keys {
                Task { await self.drive(idempotencyKey: key) }
            }
        }
    }

    // MARK: - Pipeline

    private func drive(idempotencyKey: String) async {
        let claimed: Bool = inflight.withLock { set in set.insert(idempotencyKey).inserted }
        guard claimed else { return }
        defer { inflight.withLock { set in _ = set.remove(idempotencyKey) } }

        guard var row = await fetchRow(idempotencyKey: idempotencyKey) else { return }

        if row.statusValue == .submitting {
            guard let submitted = await submit(row: row) else { return }
            row = submitted
        }

        if !row.statusValue.isTerminal, row.statusValue != .done {
            guard let polled = await poll(row: row) else { return }
            row = polled
        }

        if row.statusValue == .done {
            await invite(row: row)
        }
    }

    /// Submit the prompt. Retryable failures (5xx / transport) stay `submitting`
    /// and are retried with backoff; client errors are terminal `failed`.
    private func submit(row: DBAgentTemplateGeneration) async -> DBAgentTemplateGeneration? {
        var attempt: Int = 0
        while attempt < Constant.maxSubmitAttempts {
            do {
                let response = try await apiClient.createAgentTemplateGeneration(
                    text: row.prompt,
                    source: source,
                    clientDeviceId: clientDeviceId,
                    idempotencyKey: row.idempotencyKey
                )
                return await applyResponse(response, to: row.idempotencyKey)
            } catch let error as AgentGenerationError {
                switch error {
                case .server:
                    attempt += 1
                    await backoff(attempt: attempt)
                    continue
                case .moderationBlocked(let reason):
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: reason ?? "Content not allowed")
                case .conflict:
                    Log.error("AgentTemplateRepository: idempotency conflict for \(row.idempotencyKey)")
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: "Conflicting request")
                case .badRequest(let message):
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: message ?? "Invalid request")
                case .payloadTooLarge:
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: "Too large")
                case .notFound:
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: "Not found")
                }
            } catch {
                attempt += 1
                await backoff(attempt: attempt)
                continue
            }
        }
        return await markFailed(idempotencyKey: row.idempotencyKey, message: "Couldn't reach the builder")
    }

    /// Poll until the generation reaches `done` / `failed`. Transient errors
    /// keep polling with backoff; `404` (expired) is terminal.
    private func poll(row: DBAgentTemplateGeneration) async -> DBAgentTemplateGeneration? {
        guard let generationId = row.generationId else {
            return await markFailed(idempotencyKey: row.idempotencyKey, message: "Missing generation id")
        }
        var attempt: Int = 0
        while attempt < Constant.maxPollAttempts {
            do {
                let response = try await apiClient.getAgentTemplateGeneration(generationId: generationId)
                let updated = await applyResponse(response, to: row.idempotencyKey)
                if let updated, updated.statusValue == .done || updated.statusValue == .failed {
                    return updated
                }
            } catch let error as AgentGenerationError {
                if case .notFound = error {
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: "Build expired")
                }
            } catch {
                // network blip - keep polling
            }
            attempt += 1
            await backoff(attempt: min(attempt, Constant.pollBackoffCap))
        }
        return await markFailed(idempotencyKey: row.idempotencyKey, message: "Timed out")
    }

    /// Invite the finished template into the conversation. Provision/pool
    /// errors are retried (the template exists, so a retry is cheap); archived
    /// / not-found are terminal.
    private func invite(row: DBAgentTemplateGeneration) async {
        guard let templateId = row.templateId else {
            _ = await markFailed(idempotencyKey: row.idempotencyKey, message: "Missing template id")
            return
        }
        var attempt: Int = 0
        while attempt < Constant.maxInviteAttempts {
            do {
                Log.info("AgentTemplateRepository: inviting template \(templateId) into conversation \(row.conversationId)")
                // Direct-add the template instance into the conversation the
                // build targeted. The template carries its own generated
                // identity, so no onboarding hint is needed. Prefer the
                // session-routed handler so the provision/add runs; fall back
                // to the raw client when unset (tests).
                let handler = joinHandler.withLock { $0 }
                if let handler {
                    try await handler(row.conversationId, templateId)
                } else {
                    _ = try await apiClient.requestAgentJoin(
                        slug: nil,
                        conversationId: row.conversationId,
                        templateId: templateId,
                        options: nil,
                        forceErrorCode: nil
                    )
                }
                _ = await updateRow(idempotencyKey: row.idempotencyKey) { $0.status = DBAgentTemplateGeneration.Status.invited.rawValue }
                return
            } catch let error as APIError {
                switch error {
                case .noAgentsAvailable, .agentPoolTimeout, .agentProvisionFailed, .serverError:
                    Log.error("AgentTemplateRepository: invite retryable failure for template \(templateId): \(error) - \(error.localizedDescription)")
                    attempt += 1
                    await backoff(attempt: attempt)
                    continue
                default:
                    Log.error("AgentTemplateRepository: invite failed (non-retryable) for template \(templateId): \(error) - \(error.localizedDescription)")
                    _ = await markFailed(idempotencyKey: row.idempotencyKey, message: error.localizedDescription)
                    return
                }
            } catch {
                Log.error("AgentTemplateRepository: invite threw for template \(templateId): \(error.localizedDescription)")
                attempt += 1
                await backoff(attempt: attempt)
                continue
            }
        }
        Log.error("AgentTemplateRepository: invite exhausted retries for template \(templateId)")
        _ = await markFailed(idempotencyKey: row.idempotencyKey, message: "Agent couldn't join")
    }

    // MARK: - Row helpers

    private func applyResponse(
        _ response: ConvosAPI.AgentTemplateGenerationResponse,
        to idempotencyKey: String
    ) async -> DBAgentTemplateGeneration? {
        await updateRow(idempotencyKey: idempotencyKey) { row in
            row.generationId = response.generationId
            row.templateId = response.templateId ?? row.templateId
            switch response.status {
            case .pending:
                row.status = DBAgentTemplateGeneration.Status.pending.rawValue
            case .running:
                row.status = DBAgentTemplateGeneration.Status.running.rawValue
            case .done:
                row.status = DBAgentTemplateGeneration.Status.done.rawValue
            case .failed:
                row.status = DBAgentTemplateGeneration.Status.failed.rawValue
                row.errorMessage = response.error ?? "Generation failed"
            case .unknown:
                break
            }
            // Real preview / progress (PR #309), when present.
            if let preview = response.preview {
                row.previewAgentName = preview.agentName ?? row.previewAgentName
                row.previewEmoji = preview.emoji ?? row.previewEmoji
                row.previewDescription = preview.description ?? row.previewDescription
            }
            if let phrases = response.progressPhrases, !phrases.isEmpty {
                row.progressPhrases = Self.encodePhrases(phrases)
            }
        }
    }

    private static func encodePhrases(_ phrases: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(phrases) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodePhrases(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8),
              let phrases = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return phrases
    }

    private func markFailed(idempotencyKey: String, message: String) async -> DBAgentTemplateGeneration? {
        await updateRow(idempotencyKey: idempotencyKey) { row in
            row.status = DBAgentTemplateGeneration.Status.failed.rawValue
            row.errorMessage = message
        }
    }

    private func fetchRow(idempotencyKey: String) async -> DBAgentTemplateGeneration? {
        do {
            return try await databaseReader.read { db in
                try DBAgentTemplateGeneration.fetchOne(db, key: idempotencyKey)
            }
        } catch {
            Log.error("AgentTemplateRepository: fetch row failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func updateRow(
        idempotencyKey: String,
        _ mutate: @escaping @Sendable (inout DBAgentTemplateGeneration) -> Void
    ) async -> DBAgentTemplateGeneration? {
        do {
            return try await databaseWriter.write { db -> DBAgentTemplateGeneration? in
                guard var row = try DBAgentTemplateGeneration.fetchOne(db, key: idempotencyKey) else { return nil }
                mutate(&row)
                row.updatedAt = Date()
                try row.update(db)
                return row
            }
        } catch {
            Log.error("AgentTemplateRepository: update row failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func backoff(attempt: Int) async {
        let seconds: Double = min(Constant.baseBackoffSeconds * Double(attempt), Constant.maxBackoffSeconds)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static let terminalStatuses: [String] = [
        DBAgentTemplateGeneration.Status.invited.rawValue,
        DBAgentTemplateGeneration.Status.failed.rawValue,
    ]

    private enum Constant {
        static let maxSubmitAttempts: Int = 5
        static let maxPollAttempts: Int = 90
        static let maxInviteAttempts: Int = 6
        static let pollBackoffCap: Int = 2
        static let baseBackoffSeconds: Double = 1.0
        static let maxBackoffSeconds: Double = 3.0
    }
}

/// No-op repository used as the `SessionManagerProtocol` default so test mocks
/// and non-builder conformers don't need bespoke wiring.
public final class NoOpAgentTemplateRepository: AgentTemplateRepositoryProtocol {
    public init() {}

    public func startGeneration(prompt: String, conversationId: String, slug: String) {}

    public func generationPublisher(conversationId: String) -> AnyPublisher<AgentTemplateGeneration?, Never> {
        Just(nil).eraseToAnyPublisher()
    }

    public func resumePendingGenerations() {}

    public func configureJoinHandler(_ handler: @escaping AgentTemplateJoinHandler) {}
}
