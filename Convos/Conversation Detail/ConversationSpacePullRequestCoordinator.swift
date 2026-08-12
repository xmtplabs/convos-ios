import ConvosCore
import Foundation
import Observation

struct ConversationSpacePullRequestAlertPayload: Equatable, Identifiable {
    let title: String
    let message: String
    let pullRequestURL: URL?

    var id: String {
        "\(title)|\(message)|\(pullRequestURL?.absoluteString ?? "")"
    }
}

@MainActor
@Observable
final class ConversationSpacePullRequestCoordinator {
    typealias ProposalOperation = (String, String?) async throws -> ConvosAPI.SpacePullRequestProposalOutcome

    private let proposalOperation: ProposalOperation

    private(set) var isBusy: Bool = false
    var alert: ConversationSpacePullRequestAlertPayload?

    init(
        apiClient: any ConvosAPIClientProtocol = ConvosAPIClientFactory.client(
            environment: ConfigManager.shared.currentEnvironment
        )
    ) {
        proposalOperation = { conversationId, variantId in
            try await apiClient.proposePullRequestFromSpace(
                conversationId: conversationId,
                variantId: variantId
            )
        }
    }

    init(proposalOperation: @escaping ProposalOperation) {
        self.proposalOperation = proposalOperation
    }

    func propose(conversationId: String, variantId: String?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let outcome = try await proposalOperation(conversationId, variantId)
            alert = Self.alert(for: outcome)
        } catch {
            alert = Self.alert(for: error)
        }
    }

    private static func alert(
        for outcome: ConvosAPI.SpacePullRequestProposalOutcome
    ) -> ConversationSpacePullRequestAlertPayload {
        switch outcome {
        case .pullRequest(let pullRequest):
            return ConversationSpacePullRequestAlertPayload(
                title: "Pull request proposed",
                message: "A draft pull request is ready to review.",
                pullRequestURL: pullRequest.prURL
            )
        case .unchanged:
            return ConversationSpacePullRequestAlertPayload(
                title: "Already matches the starter",
                message: "This Space has no changes to propose.",
                pullRequestURL: nil
            )
        }
    }

    private static func alert(for error: Error) -> ConversationSpacePullRequestAlertPayload {
        if let proposalError = error as? ConvosAPI.SpacePullRequestProposalError {
            return alert(for: proposalError)
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return alert(for: .timeout)
        }
        return ConversationSpacePullRequestAlertPayload(
            title: "Couldn't propose a pull request",
            message: "Try again. If the problem continues, check the selected deployment.",
            pullRequestURL: nil
        )
    }

    private static func alert(
        for error: ConvosAPI.SpacePullRequestProposalError
    ) -> ConversationSpacePullRequestAlertPayload {
        let title: String
        let message: String
        switch error {
        case .invalidRequest:
            title = "Invalid conversation"
            message = "This conversation can't be used for a Space pull request proposal."
        case .notArmed:
            title = "Deployment not armed"
            message = "The selected deployment is not configured to propose Space pull requests."
        case .spaceNotFound:
            title = "No Space found"
            message = "The selected deployment has no Space for this conversation."
        case .repositoryUnavailable:
            title = "Repository unavailable"
            message = "This Space is not connected to a repository."
        case .refused:
            title = "Proposal refused"
            message = "The Space contains changes that can't be proposed safely."
        case .variantUnavailable:
            title = "Variant unavailable"
            message = "This conversation's agent variant is no longer available."
        case .timeout:
            title = "Request timed out"
            message = "The request timed out. The PR may still have been updated; it is safe to try again."
        case .githubFailed:
            title = "GitHub rejected the proposal"
            message = "Check repository access and try again."
        case .unavailable:
            title = "Proposal unavailable"
            message = "The selected deployment does not support this action yet."
        case .failed:
            title = "Couldn't propose a pull request"
            message = "Try again. If the problem continues, check the selected deployment."
        case .rateLimited:
            title = "Too many proposals"
            message = "Wait a moment, then try again."
        }
        return ConversationSpacePullRequestAlertPayload(
            title: title,
            message: message,
            pullRequestURL: nil
        )
    }
}
