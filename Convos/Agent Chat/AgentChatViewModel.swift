import ConvosCore
import Foundation
import Observation

@MainActor
@Observable
final class AgentChatViewModel {
    let provider: ExternalAgentProvider
    var turns: [AgentTurn] = []
    var composerText: String = ""
    var errorMessage: String?
    var isSubmitting: Bool = false

    private let dependencies: AgentRelayDependencies
    private let waitUntilReady: @Sendable () async throws -> Void
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var submissionTask: Task<Void, Never>?

    init(
        provider: ExternalAgentProvider,
        dependencies: AgentRelayDependencies,
        initialText: String = "",
        waitUntilReady: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.provider = provider
        self.dependencies = dependencies
        self.waitUntilReady = waitUntilReady
        self.composerText = initialText
        let initialTurns: [AgentTurn] = (try? dependencies.repository.turns(provider: provider, limit: Constant.turnLimit)) ?? []
        self.turns = initialTurns
        observeTurns()
    }

    init(
        provider: ExternalAgentProvider,
        dependencies: AgentRelayDependencies,
        session: any SessionManagerProtocol,
        initialText: String = ""
    ) {
        self.provider = provider
        self.dependencies = dependencies
        self.waitUntilReady = {
            _ = try await session.messagingService().sessionStateManager.waitForInboxReadyResult()
        }
        self.composerText = initialText
        let initialTurns: [AgentTurn] = (try? dependencies.repository.turns(provider: provider, limit: Constant.turnLimit)) ?? []
        self.turns = initialTurns
        observeTurns()
    }

    /// Only the composer's content gates sending. A turn already in flight
    /// does not: sending supersedes it (see `submit()`), which is the escape
    /// hatch from a turn that is going nowhere.
    var canSubmit: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The turn this device is currently waiting on, if any. At most one:
    /// sending stops waiting on the previous one.
    var inFlightTurn: AgentTurn? {
        turns.last { $0.status == .pending }
    }

    var connectedProviders: [ExternalAgentProvider] {
        ExternalAgentProvider.allCases.filter { candidate in
            (try? dependencies.connectionStore.load(provider: candidate)) != nil
        }
    }

    func prefill(text: String) {
        composerText = text
    }

    /// Stops waiting on whatever is in flight, then sends. The agent on its
    /// own platform keeps working either way - this device only stops
    /// watching, and a late answer still lands in the superseded turn's place.
    func submit() {
        let prompt: String = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        perform(prompt: prompt, clearsComposerWhenReady: true)
    }

    func retry(turn: AgentTurn) {
        stopWaitingOnInFlightTurns()
        perform(prompt: turn.prompt)
    }

    /// Explicit "stop waiting" on one turn, for a user who wants the transcript
    /// to settle without sending anything new.
    func stopWaiting(turn: AgentTurn) {
        guard turn.status == .pending else { return }
        submissionTask?.cancel()
        submissionTask = nil
        isSubmitting = false
        do {
            try dependencies.writer.markSuperseded(requestId: turn.requestId)
        } catch {
            Log.warning("Agent relay could not stop waiting on a turn")
        }
    }

    func checkAgain(turn: AgentTurn) {
        guard turn.status == .pending || turn.status == .superseded else { return }
        errorMessage = nil
        isSubmitting = true
        let dependencies = dependencies
        let provider = provider
        submissionTask = Task { [weak self] in
            defer { self?.isSubmitting = false }
            do {
                let result = try await dependencies.client.collect(
                    requestId: turn.requestId,
                    provider: provider
                )
                guard result == nil else { return }
                let currentStatus: AgentTurnStatus? = try dependencies.repository.turn(requestId: turn.requestId)?.status
                guard currentStatus == .pending || currentStatus == .superseded else { return }
                let outcome = try await dependencies.client.watch(requestId: turn.requestId)
                self?.apply(outcome)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = AgentSetupCopy.errorMessage(error, provider: provider)
            }
        }
    }

    /// True while this provider has something a clear would actually remove.
    /// A transcript holding nothing but the turn in flight has nothing to
    /// clear, so the menu item is disabled rather than opening a dialog that
    /// would delete nothing.
    var hasClearableHistory: Bool {
        turns.contains { turn in
            turn.status != .pending && turn.status != .superseded
        }
    }

    /// Drops this provider's finished transcript rows and releases the mailboxes
    /// the backend is still holding for them, so a cleared history cannot come
    /// back on the next launch. Pending and superseded turns are left alone.
    ///
    /// A completed turn whose ack never landed can still own a live mailbox, so
    /// it is acknowledged before deletion. Failed, expired, and
    /// collected-elsewhere turns have no mailbox left to release.
    func clearHistory() {
        let dependencies = dependencies
        let provider = provider
        Task { [weak self] in
            do {
                let settledTurns = try dependencies.writer.settledTurns(provider: provider)
                var firstError: (any Error)?
                for turn in settledTurns {
                    do {
                        if turn.requiresMailboxAcknowledgementBeforeDeletion {
                            try await dependencies.client.acknowledge(requestId: turn.requestId)
                            try dependencies.writer.markAcked(requestId: turn.requestId)
                        }
                        try dependencies.writer.deleteSettledTurn(requestId: turn.requestId)
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
            } catch {
                self?.errorMessage = "Convos could not clear this history. Try again."
            }
        }
    }

    func userFacingError(for turn: AgentTurn) -> String {
        guard let code = turn.errorCode else {
            return AgentSetupCopy.genericFailure
        }
        if let message = AgentSetupCopy.errorMessage(forCode: code, provider: turn.provider) {
            return message
        }
        return AgentSetupCopy.genericFailure
    }

    func isStillWorking(_ turn: AgentTurn, now: Date) -> Bool {
        turn.status == .pending && now >= watchDeadline(for: turn)
    }

    /// When this device gives up watching a turn and the transcript starts
    /// offering "Check again" instead. The pending bubble reads it so the
    /// deadline lives in one place.
    func watchDeadline(for turn: AgentTurn) -> Date {
        turn.createdAt.addingTimeInterval(Constant.watchDeadline)
    }

    private func stopWaitingOnInFlightTurns() {
        submissionTask?.cancel()
        submissionTask = nil
        isSubmitting = false
        markInFlightTurnsSuperseded()
    }

    private func markInFlightTurnsSuperseded() {
        for turn in turns where turn.status == .pending {
            do {
                try dependencies.writer.markSuperseded(requestId: turn.requestId)
            } catch {
                Log.warning("Agent relay could not stop waiting on a turn")
            }
        }
    }

    private func perform(prompt: String, clearsComposerWhenReady: Bool = false) {
        errorMessage = nil
        isSubmitting = true
        let dependencies = dependencies
        let provider = provider
        let waitUntilReady = waitUntilReady
        let previousSubmissionTask = submissionTask
        submissionTask = Task { [weak self] in
            defer { self?.isSubmitting = false }
            do {
                guard let connection = try dependencies.connectionStore.load(provider: provider) else {
                    throw AgentRelayError.notConnected
                }
                try await waitUntilReady()
                if clearsComposerWhenReady {
                    previousSubmissionTask?.cancel()
                    if self?.composerText == prompt {
                        self?.composerText = ""
                    }
                    self?.markInFlightTurnsSuperseded()
                }
                let outcome = try await dependencies.client.send(
                    prompt: prompt,
                    connection: connection
                )
                self?.apply(outcome)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = AgentSetupCopy.errorMessage(error, provider: provider)
            }
        }
    }

    /// The transcript already carries every outcome as its own bubble, so only
    /// the ones that leave no bubble behind become the composer notice.
    private func apply(_ outcome: AgentTurnOutcome) {
        switch outcome {
        case .completed:
            removeNotificationsForCompletedTurns(turns)
        case .failed(let error):
            errorMessage = AgentSetupCopy.errorMessage(error, provider: provider)
        case .expired, .stillWorking, .collectedElsewhere:
            break
        }
    }

    private func observeTurns() {
        let stream = dependencies.repository.turnsStream(provider: provider, limit: Constant.turnLimit)
        observationTask = Task { [weak self] in
            for await updatedTurns in stream {
                guard !Task.isCancelled else { return }
                self?.applyObservedTurns(updatedTurns)
            }
        }
    }

    private func applyObservedTurns(_ updatedTurns: [AgentTurn]) {
        turns = updatedTurns
        removeNotificationsForCompletedTurns(updatedTurns)
    }

    private func removeNotificationsForCompletedTurns(_ updatedTurns: [AgentTurn]) {
        let identifiers: [String] = updatedTurns.compactMap { turn in
            turn.status == .completed ? turn.requestId : nil
        }
        for identifier in identifiers {
            ConvosAppDelegate.removeDeliveredAgentRelayNotification(requestId: identifier)
        }
    }

    deinit {
        observationTask?.cancel()
        submissionTask?.cancel()
    }

    private enum Constant {
        static let turnLimit: Int = 200
        static let watchDeadline: TimeInterval = 10 * 60
    }
}

private extension AgentTurn {
    var requiresMailboxAcknowledgementBeforeDeletion: Bool {
        switch status {
        case .completed:
            return ackedAt == nil
        case .pending, .failed, .expired, .collectedElsewhere, .superseded:
            return false
        }
    }
}
