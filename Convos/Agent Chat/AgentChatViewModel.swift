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
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(
        provider: ExternalAgentProvider,
        dependencies: AgentRelayDependencies,
        initialText: String = ""
    ) {
        self.provider = provider
        self.dependencies = dependencies
        self.composerText = initialText
        let initialTurns: [AgentTurn] = (try? dependencies.repository.turns(limit: Constant.turnLimit)) ?? []
        self.turns = initialTurns.filter { $0.provider == provider }
        observeTurns()
    }

    var canSubmit: Bool {
        let prompt: String = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRecentPending: Bool = turns.contains { turn in
            turn.provider == provider
                && turn.status == .pending
                && Date().timeIntervalSince(turn.createdAt) < Constant.watchDeadline
        }
        return !prompt.isEmpty && !isSubmitting && !hasRecentPending
    }

    var connectedProviders: [ExternalAgentProvider] {
        ExternalAgentProvider.allCases.filter { candidate in
            (try? dependencies.connectionStore.load(provider: candidate)) != nil
        }
    }

    func prefill(text: String) {
        composerText = text
    }

    func submit() {
        let prompt: String = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !prompt.isEmpty else { return }
        composerText = ""
        perform(prompt: prompt)
    }

    func retry(turn: AgentTurn) {
        guard !isSubmitting else { return }
        perform(prompt: turn.prompt)
    }

    func userFacingError(for turn: AgentTurn) -> String {
        guard let code = turn.errorCode else {
            return "Something went wrong. Try again."
        }
        if code == "notConnected" {
            return "Connect this agent first."
        }
        if code == "relayUnreachable" {
            return "Convos could not reach the relay. Try again."
        }
        if code == "webhookUnreachable" {
            return "Convos could not reach \(turn.provider.displayName). Check the webhook URL and try again."
        }
        if code == "unreadableResult" {
            return "The agent reply could not be read. Send it again."
        }
        if code == "expired" {
            return "This request expired; send it again."
        }
        if code == "stillWorking" {
            return "Still working after ten minutes; you will get a notification when it replies."
        }
        if let message = rejectionMessage(code: code, provider: turn.provider) {
            return message
        }
        return "Something went wrong. Try again."
    }

    func isStillWorking(_ turn: AgentTurn, now: Date) -> Bool {
        turn.status == .pending && now.timeIntervalSince(turn.createdAt) >= Constant.watchDeadline
    }

    private func perform(prompt: String) {
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                guard let connection = try dependencies.connectionStore.load(provider: provider) else {
                    throw AgentRelayError.notConnected
                }
                let outcome = try await dependencies.client.send(
                    prompt: prompt,
                    provider: provider,
                    connection: connection
                )
                apply(outcome)
            } catch {
                errorMessage = AgentSetupCopy.errorMessage(error, provider: provider)
            }
        }
    }

    private func apply(_ outcome: AgentTurnOutcome) {
        switch outcome {
        case .completed:
            removeNotificationsForCompletedTurns(turns)
        case .failed(let error):
            errorMessage = AgentSetupCopy.errorMessage(error, provider: provider)
        case .expired:
            errorMessage = "This request expired; send it again."
        case .stillWorking:
            errorMessage = "Still working after ten minutes; you will get a notification when it replies."
        case .collectedElsewhere:
            errorMessage = "This reply was collected on another device."
        }
    }

    private func observeTurns() {
        let stream = dependencies.repository.turnsStream(limit: Constant.turnLimit)
        observationTask = Task { [weak self] in
            for await updatedTurns in stream {
                guard !Task.isCancelled else { return }
                self?.applyObservedTurns(updatedTurns)
            }
        }
    }

    private func applyObservedTurns(_ updatedTurns: [AgentTurn]) {
        let providerTurns: [AgentTurn] = updatedTurns.filter { $0.provider == provider }
        turns = providerTurns
        removeNotificationsForCompletedTurns(providerTurns)
    }

    private func removeNotificationsForCompletedTurns(_ updatedTurns: [AgentTurn]) {
        let identifiers: [String] = updatedTurns.compactMap { turn in
            turn.status == .completed ? turn.requestId : nil
        }
        for identifier in identifiers {
            ConvosAppDelegate.removeDeliveredAgentRelayNotification(requestId: identifier)
        }
    }

    private func rejectionMessage(code: String, provider: ExternalAgentProvider) -> String? {
        let parts: [Substring] = code.split(separator: ":")
        guard let statusText = parts.last, let status = Int(statusText) else { return nil }
        if code.hasPrefix("relayRejected:") {
            return "The relay rejected the request (\(status)). Try again."
        }
        if code.hasPrefix("webhookRejected:") {
            return AgentSetupCopy.errorMessage(
                .webhookRejected(provider: provider, status: status),
                provider: provider
            )
        }
        return nil
    }

    deinit {
        observationTask?.cancel()
    }

    private enum Constant {
        static let turnLimit: Int = 200
        static let watchDeadline: TimeInterval = 10 * 60
    }
}
