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
    /// In-progress draft identity; `nil` until the first preview.
    public let preview: ConvosAPI.AgentPreview?
    /// In-progress build-narration lines; `[]` when none.
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
/// the build targeted. `joinIdempotencyKey` is the persisted key the
/// repository mints per logical join; the handler must send it on the join
/// POST so a retried join dedups server-side.
public typealias AgentTemplateJoinHandler = @Sendable (_ conversationId: String, _ templateId: String, _ variantId: String?, _ joinIdempotencyKey: ConvosAPI.JoinIdempotencyKey?) async throws -> Void

/// Errors an `AgentTemplateJoinHandler` can throw when it cannot perform the
/// join. Surfacing these as thrown errors (rather than returning) keeps the
/// repository's invite step from recording a false `.invited`.
public enum AgentTemplateJoinError: Error {
    /// The session that owns the join handler was deallocated before the invite
    /// ran, so no agent could be added. The invite step retries / fails instead
    /// of treating the no-op as success.
    case sessionUnavailable
}

/// A local media input for a build, handed to `startGeneration`. The repository
/// persists a copy, uploads the plaintext bytes to the agent-templates presigned
/// endpoint, and references the resulting object key in `inputs.attachments[]`.
public struct AgentBuildAttachmentInput: Sendable {
    public let data: Data
    public let mimeType: String
    public let filename: String?

    public init(data: Data, mimeType: String, filename: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
    }
}

public protocol AgentTemplateRepositoryProtocol: Sendable {
    /// Kicks off a generation for `conversationId`. Persists the row (and a copy
    /// of any attachments) first, then drives upload -> submit -> poll -> invite
    /// in the background. Safe to call once per build; the persisted row makes it
    /// idempotent across relaunch. `connections` are neutral service ids sent
    /// for generation awareness; post-join grants are driven separately.
    /// `variantId` is the dev-only agent variant slug captured once at build
    /// start (`nil` for default builds); it is persisted on the row and reused
    /// for the generation, join, and join-status-poll calls.
    func startGeneration(prompt: String, conversationId: String, slug: String, attachments: [AgentBuildAttachmentInput], connections: [String], variantId: String?)

    /// Latest generation for a conversation, observed reactively.
    func generationPublisher(conversationId: String) -> AnyPublisher<AgentTemplateGeneration?, Never>

    /// Re-drives any non-terminal rows after an app relaunch.
    func resumePendingGenerations()

    /// Deletes the persisted generation row(s) for a conversation once the
    /// build's agent has joined. The activating card is gated on "no verified
    /// agent present", so a persisted (terminal) row would otherwise resurrect
    /// the card if the agent is later removed; clearing the row makes that
    /// durable across removal and relaunch. No-op when there's no row.
    func clearGeneration(conversationId: String)

    /// Inject the session-routed join (set once at session init). When set,
    /// the invite step uses it instead of the raw API client so the join
    /// polling runs.
    func configureJoinHandler(_ handler: @escaping AgentTemplateJoinHandler)
}

public extension AgentTemplateRepositoryProtocol {
    /// Text-only convenience for callers with no attachments or connections.
    func startGeneration(prompt: String, conversationId: String, slug: String) {
        startGeneration(prompt: prompt, conversationId: conversationId, slug: slug, attachments: [], connections: [], variantId: nil)
    }
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
    /// Resolved lazily at submit time (not at init) so constructing the
    /// repository -- which happens at `SessionManager` init -- never forces a
    /// `DeviceInfo` read. The id is only needed when a generation is actually
    /// submitted, by which point the platform layer has configured `DeviceInfo`.
    private let clientDeviceIdProvider: @Sendable () -> String?

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
        clientDeviceIdProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.source = source
        self.clientDeviceIdProvider = clientDeviceIdProvider
    }

    // MARK: - Public

    public func configureJoinHandler(_ handler: @escaping AgentTemplateJoinHandler) {
        joinHandler.withLock { $0 = handler }
    }

    public func startGeneration(prompt: String, conversationId: String, slug: String, attachments: [AgentBuildAttachmentInput], connections: [String], variantId: String?) {
        let idempotencyKey: String = UUID().uuidString
        let now: Date = Date()
        let storedAttachments: [StoredGenerationAttachment]
        do {
            storedAttachments = try Self.persistAttachmentFiles(attachments, idempotencyKey: idempotencyKey)
        } catch {
            Log.error("AgentTemplateRepository: failed to persist attachment files: \(error.localizedDescription)")
            return
        }
        let row = DBAgentTemplateGeneration(
            idempotencyKey: idempotencyKey,
            generationId: nil,
            conversationId: conversationId,
            slug: slug,
            status: .submitting,
            templateId: nil,
            prompt: prompt,
            errorMessage: nil,
            attachments: Self.encodeAttachments(storedAttachments),
            connections: Self.encodeConnections(connections),
            variantId: variantId,
            createdAt: now,
            updatedAt: now
        )
        Log.info("AgentTemplateRepository: starting generation \(idempotencyKey) for conversation \(conversationId)")
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

    public func clearGeneration(conversationId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.databaseWriter.write { db in
                    try DBAgentTemplateGeneration
                        .filter(DBAgentTemplateGeneration.Columns.conversationId == conversationId)
                        .deleteAll(db)
                }
            } catch {
                Log.error("AgentTemplateRepository: clearGeneration failed: \(error.localizedDescription)")
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
            guard let uploaded = await uploadAttachments(row: row) else { return }
            row = uploaded
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
                let attachmentRefs = Self.attachmentRefs(from: row)
                let response = try await apiClient.createAgentTemplateGeneration(
                    inputs: .init(text: row.prompt, attachments: attachmentRefs.isEmpty ? nil : attachmentRefs),
                    source: source,
                    clientDeviceId: clientDeviceIdProvider(),
                    idempotencyKey: row.idempotencyKey,
                    connections: Self.decodeConnections(row.connections),
                    variantId: row.variantId
                )
                return await applyResponse(response, to: row.idempotencyKey)
            } catch let error as AgentGenerationError {
                switch error {
                case .server(let message):
                    Log.error("AgentTemplateRepository: submit server error (attempt \(attempt + 1)/\(Constant.maxSubmitAttempts)): \(message ?? "no message")")
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
                Log.error("AgentTemplateRepository: submit failed (attempt \(attempt + 1)/\(Constant.maxSubmitAttempts)): \(error.localizedDescription)")
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
                    if updated.statusValue == .failed {
                        Log.error("AgentTemplateRepository: generation \(generationId) reported failed by backend: \(updated.errorMessage ?? "no error message")")
                    }
                    return updated
                }
            } catch let error as AgentGenerationError {
                if case .notFound = error {
                    return await markFailed(idempotencyKey: row.idempotencyKey, message: "Build expired")
                }
                Log.warning("AgentTemplateRepository: poll error for generation \(generationId) (attempt \(attempt + 1)/\(Constant.maxPollAttempts)): \(error)")
            } catch {
                // network blip - keep polling
                Log.warning("AgentTemplateRepository: poll transient error for generation \(generationId) (attempt \(attempt + 1)/\(Constant.maxPollAttempts)): \(error.localizedDescription)")
            }
            attempt += 1
            await backoff(attempt: min(attempt, Constant.pollBackoffCap))
        }
        return await markFailed(idempotencyKey: row.idempotencyKey, message: "Timed out")
    }

    /// Returns the row's persisted join idempotency key, minting and
    /// persisting one first when absent (or when the persisted value is not a
    /// valid key). Persisting before the POST is the point: a retry after a
    /// lost response - including a relaunch resume - resends the same key and
    /// the server adopts the in-flight instance instead of provisioning a
    /// duplicate.
    ///
    /// Returns `nil` only when the generation row no longer exists (e.g.
    /// `clearGeneration` ran while the pipeline was between steps); the invite
    /// is moot then and the caller exits. A persist that fails while the row
    /// still exists proceeds with the in-memory key instead of blocking the
    /// join: in-process retries still reuse it, and the residual relaunch
    /// window degrades to the pre-key behavior rather than failing a build
    /// that can succeed now.
    private func ensureJoinIdempotencyKey(row: DBAgentTemplateGeneration) async -> ConvosAPI.JoinIdempotencyKey? {
        if let persisted = row.joinIdempotencyKey,
           let key = ConvosAPI.JoinIdempotencyKey(rawValue: persisted) {
            Log.info("AgentTemplateRepository: join key reused from persistence \(key.rawValue) for generation \(row.idempotencyKey)")
            return key
        }
        let minted = ConvosAPI.JoinIdempotencyKey.mint()
        let persistedRow = await updateRow(idempotencyKey: row.idempotencyKey) { $0.joinIdempotencyKey = minted.rawValue }
        if persistedRow != nil {
            Log.info("AgentTemplateRepository: join key minted and persisted \(minted.rawValue) for generation \(row.idempotencyKey)")
            return minted
        }
        // updateRow returning nil conflates "row gone" with "write failed";
        // distinguish them so a cleared build stops here instead of joining.
        guard await fetchRow(idempotencyKey: row.idempotencyKey) != nil else {
            Log.info("AgentTemplateRepository: generation \(row.idempotencyKey) row gone before invite; skipping join")
            return nil
        }
        Log.warning("AgentTemplateRepository: join key \(minted.rawValue) minted but persist failed for generation \(row.idempotencyKey); proceeding unpersisted (a relaunch resume would re-mint)")
        return minted
    }

    /// Invite the finished template into the conversation. Provision/pool
    /// errors are retried (the template exists, so a retry is cheap); archived
    /// / not-found are terminal. Retries reuse the persisted join idempotency
    /// key on ambiguous failures (timeout, lost connection) so the server
    /// adopts the in-flight instance, and mint a fresh key after an explicit
    /// provision failure because the server retains the failed instance under
    /// the old key.
    private func invite(row: DBAgentTemplateGeneration) async {
        guard let templateId = row.templateId else {
            _ = await markFailed(idempotencyKey: row.idempotencyKey, message: "Missing template id")
            return
        }
        guard let ensuredKey = await ensureJoinIdempotencyKey(row: row) else {
            // Row cleared while the pipeline was between steps; nothing to invite.
            return
        }
        var joinKey: ConvosAPI.JoinIdempotencyKey = ensuredKey
        Log.info("AgentTemplateRepository: inviting template \(templateId) into conversation \(row.conversationId) with join key \(joinKey.rawValue)")
        var attempt: Int = 0
        while attempt < Constant.maxInviteAttempts {
            do {
                // Direct-add the template instance into the conversation the
                // build targeted. The template carries its own generated
                // identity, so no onboarding hint is needed. Prefer the
                // session-routed handler so the provision/add runs; fall back
                // to the raw client when unset (tests).
                let handler = joinHandler.withLock { $0 }
                if let handler {
                    try await handler(row.conversationId, templateId, row.variantId, joinKey)
                } else {
                    // Reaching this outside tests means the agent gets provisioned
                    // but never direct-added, so it silently never joins.
                    Log.warning("AgentTemplateRepository: join handler unset; raw join without direct-add for template \(templateId)")
                    let options = row.variantId.map { ConvosAPI.AgentJoinOptions(onboarding: nil, variantId: $0) }
                    _ = try await apiClient.requestAgentJoin(
                        ConvosAPI.AgentJoinRequest(
                            conversationId: row.conversationId,
                            templateId: templateId,
                            idempotencyKey: joinKey,
                            options: options
                        ),
                        forceErrorCode: nil
                    )
                }
                Log.info("AgentTemplateRepository: invite succeeded for template \(templateId) in conversation \(row.conversationId) with join key \(joinKey.rawValue)")
                Self.cleanupAttachments(idempotencyKey: row.idempotencyKey)
                _ = await updateRow(idempotencyKey: row.idempotencyKey) { $0.status = DBAgentTemplateGeneration.Status.invited.rawValue }
                return
            } catch let error as APIError {
                switch error {
                case .agentProvisionFailed:
                    // Explicit provision failure: the server retains the failed
                    // instance under this key, so a same-key retry would adopt
                    // the corpse. Mint a fresh key for the next attempt.
                    let corpseKey = joinKey.rawValue
                    joinKey = ConvosAPI.JoinIdempotencyKey.mint()
                    let reminted = joinKey.rawValue
                    Log.error("AgentTemplateRepository: invite provision failed for template \(templateId); join key re-minted \(corpseKey) -> \(reminted): \(error.localizedDescription)")
                    let remintPersisted = await updateRow(idempotencyKey: row.idempotencyKey) { $0.joinIdempotencyKey = reminted }
                    if remintPersisted == nil, await fetchRow(idempotencyKey: row.idempotencyKey) == nil {
                        // Row cleared mid-invite; stop retrying a build that
                        // no longer exists.
                        Log.info("AgentTemplateRepository: generation \(row.idempotencyKey) row gone during invite; skipping retry")
                        return
                    }
                    attempt += 1
                    await backoff(attempt: attempt)
                    continue
                case .noAgentsAvailable, .agentPoolTimeout, .serverError:
                    // Ambiguous or no-instance failures: reuse the key so a
                    // provision that did land server-side is adopted, not
                    // duplicated.
                    Log.error("AgentTemplateRepository: invite retryable failure for template \(templateId); reusing join key \(joinKey.rawValue): \(error) - \(error.localizedDescription)")
                    attempt += 1
                    await backoff(attempt: attempt)
                    continue
                case .forbidden:
                    // A cold-launch resume can reach the backend before the
                    // SIWE-bound JWT is ready, surfacing 403 "Account required"
                    // as a readiness race rather than a real authorization
                    // verdict. Retry with backoff reusing the key: once auth is
                    // ready, the same key adopts any instance an earlier attempt
                    // already provisioned. A genuinely unauthorized caller still
                    // fails terminally once attempts are exhausted.
                    Log.error("AgentTemplateRepository: invite got 403 (auth may not be ready yet); retrying with join key \(joinKey.rawValue): \(error.localizedDescription)")
                    attempt += 1
                    await backoff(attempt: attempt)
                    continue
                default:
                    Log.error("AgentTemplateRepository: invite failed (non-retryable) for template \(templateId): \(error) - \(error.localizedDescription)")
                    _ = await markFailed(idempotencyKey: row.idempotencyKey, message: error.localizedDescription)
                    return
                }
            } catch {
                // Transport-level failure (timeout, lost connection) - the
                // ambiguous case the key exists for. Reuse it so the server
                // adopts the possibly-provisioned instance.
                let urlErrorCode = (error as? URLError).map { " urlError=\($0.code.rawValue)" } ?? ""
                Log.error("AgentTemplateRepository: invite threw (ambiguous) for template \(templateId); reusing join key \(joinKey.rawValue)\(urlErrorCode): \(error.localizedDescription)")
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
            let previousStatus = row.status
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
            // Real preview / progress, when present.
            if let preview = response.preview {
                row.previewAgentName = preview.agentName ?? row.previewAgentName
                row.previewEmoji = preview.emoji ?? row.previewEmoji
                row.previewDescription = preview.description ?? row.previewDescription
            }
            if let phrases = response.progressPhrases, !phrases.isEmpty {
                row.progressPhrases = Self.encodePhrases(phrases)
            }
            if row.status != previousStatus {
                Log.info("AgentTemplateRepository: generation \(response.generationId) status \(previousStatus) -> \(row.status)")
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

    // MARK: - Attachments

    /// Uploads any not-yet-uploaded attachments to the agent-templates presigned
    /// endpoint, persisting each object key as it lands. Returns the updated row,
    /// or `nil` if a terminal failure was recorded. A row with no pending
    /// attachments passes straight through.
    private func uploadAttachments(row: DBAgentTemplateGeneration) async -> DBAgentTemplateGeneration? {
        var stored = Self.decodeAttachments(row.attachments)
        guard stored.contains(where: { $0.objectKey == nil }) else { return row }
        for index in stored.indices where stored[index].objectKey == nil {
            let descriptor = stored[index]
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: descriptor.localPath))
            } catch {
                Log.error("AgentTemplateRepository: missing attachment file at \(descriptor.localPath): \(error.localizedDescription)")
                _ = await markFailed(idempotencyKey: row.idempotencyKey, message: "Attachment upload failed")
                return nil
            }
            do {
                let presigned = try await apiClient.getAgentTemplateAttachmentPresignedURL(
                    contentType: descriptor.mimeType,
                    contentLength: data.count
                )
                try await apiClient.uploadAgentTemplateAttachment(
                    data: data,
                    contentType: descriptor.mimeType,
                    to: presigned.uploadURL
                )
                stored[index].objectKey = presigned.objectKey
            } catch {
                Log.error("AgentTemplateRepository: attachment upload failed: \(error.localizedDescription)")
                _ = await markFailed(idempotencyKey: row.idempotencyKey, message: "Attachment upload failed")
                return nil
            }
        }
        let encoded = Self.encodeAttachments(stored)
        return await updateRow(idempotencyKey: row.idempotencyKey) { $0.attachments = encoded }
    }

    private static func persistAttachmentFiles(
        _ inputs: [AgentBuildAttachmentInput],
        idempotencyKey: String
    ) throws -> [StoredGenerationAttachment] {
        guard !inputs.isEmpty else { return [] }
        let dir = attachmentsDirectory(idempotencyKey: idempotencyKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stored: [StoredGenerationAttachment] = []
        for input in inputs {
            let fileURL = dir.appendingPathComponent(UUID().uuidString)
            try input.data.write(to: fileURL)
            stored.append(
                StoredGenerationAttachment(
                    objectKey: nil,
                    mimeType: input.mimeType,
                    filename: input.filename,
                    localPath: fileURL.path
                )
            )
        }
        return stored
    }

    private static func attachmentsDirectory(idempotencyKey: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBuildAttachments", isDirectory: true)
            .appendingPathComponent(idempotencyKey, isDirectory: true)
    }

    private static func encodeAttachments(_ attachments: [StoredGenerationAttachment]) -> String? {
        guard !attachments.isEmpty,
              let data = try? JSONEncoder().encode(attachments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeAttachments(_ json: String?) -> [StoredGenerationAttachment] {
        guard let data = json?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([StoredGenerationAttachment].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func attachmentRefs(from row: DBAgentTemplateGeneration) -> [ConvosAPI.AttachmentRef] {
        decodeAttachments(row.attachments).compactMap { (stored: StoredGenerationAttachment) -> ConvosAPI.AttachmentRef? in
            guard let objectKey = stored.objectKey else { return nil }
            return ConvosAPI.AttachmentRef(objectKey: objectKey, mimeType: stored.mimeType, filename: stored.filename)
        }
    }

    private static func cleanupAttachments(idempotencyKey: String) {
        try? FileManager.default.removeItem(at: attachmentsDirectory(idempotencyKey: idempotencyKey))
    }

    private static func encodeConnections(_ connections: [String]) -> String? {
        guard !connections.isEmpty,
              let data = try? JSONEncoder().encode(connections) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeConnections(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func markFailed(idempotencyKey: String, message: String) async -> DBAgentTemplateGeneration? {
        Log.error("AgentTemplateRepository: generation \(idempotencyKey) marked failed: \(message)")
        Self.cleanupAttachments(idempotencyKey: idempotencyKey)
        return await updateRow(idempotencyKey: idempotencyKey) { row in
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
    public func startGeneration(prompt: String, conversationId: String, slug: String, attachments: [AgentBuildAttachmentInput], connections: [String], variantId: String?) {}

    public init() {}

    public func generationPublisher(conversationId: String) -> AnyPublisher<AgentTemplateGeneration?, Never> {
        Just(nil).eraseToAnyPublisher()
    }

    public func resumePendingGenerations() {}

    public func clearGeneration(conversationId: String) {}

    public func configureJoinHandler(_ handler: @escaping AgentTemplateJoinHandler) {}
}
