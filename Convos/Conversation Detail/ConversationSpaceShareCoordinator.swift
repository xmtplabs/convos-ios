import ConvosCore
import Foundation
import Observation
import UIKit

struct ConversationSpaceShareAlertPayload: Equatable {
    let title: String
    let message: String
}

/// Mints a Space share message through the backend relay and puts it on the
/// clipboard. The message embeds an expiring read-only repository credential,
/// so it goes straight from the response to the pasteboard — never into logs
/// or alert text.
@MainActor
@Observable
final class ConversationSpaceShareCoordinator {
    typealias ShareOperation = (String, String?) async throws -> ConvosAPI.SpaceShareLink
    typealias CopyToClipboard = (String) -> Void

    private let shareOperation: ShareOperation
    private let copyToClipboard: CopyToClipboard

    private(set) var isBusy: Bool = false
    var alert: ConversationSpaceShareAlertPayload?

    init(
        apiClient: any ConvosAPIClientProtocol = ConvosAPIClientFactory.client(
            environment: ConfigManager.shared.currentEnvironment
        )
    ) {
        shareOperation = { conversationId, variantId in
            try await apiClient.shareSpace(
                conversationId: conversationId,
                variantId: variantId
            )
        }
        copyToClipboard = { UIPasteboard.general.string = $0 }
    }

    init(
        shareOperation: @escaping ShareOperation,
        copyToClipboard: @escaping CopyToClipboard
    ) {
        self.shareOperation = shareOperation
        self.copyToClipboard = copyToClipboard
    }

    func share(conversationId: String, variantId: String?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let link = try await shareOperation(conversationId, variantId)
            copyToClipboard(link.message)
            alert = ConversationSpaceShareAlertPayload(
                title: "Copied to clipboard",
                message: "Paste it into another conversation and that agent will rebuild this Space there. The link works for 7 days."
            )
        } catch {
            alert = Self.alert(for: error)
        }
    }

    private static func alert(for error: Error) -> ConversationSpaceShareAlertPayload {
        if let shareError = error as? ConvosAPI.SpaceShareError {
            return alert(for: shareError)
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return alert(for: .timeout)
        }
        return ConversationSpaceShareAlertPayload(
            title: "Couldn't create a share link",
            message: "Try again. If the problem continues, check the selected deployment."
        )
    }

    private static func alert(for error: ConvosAPI.SpaceShareError) -> ConversationSpaceShareAlertPayload {
        let title: String
        let message: String
        switch error {
        case .invalidRequest:
            title = "Invalid conversation"
            message = "This conversation can't be used for a Space share link."
        case .spaceNotFound:
            title = "No Space found"
            message = "The selected deployment has no Space for this conversation."
        case .repositoryUnavailable:
            title = "Repository unavailable"
            message = "This Space is not connected to a repository."
        case .variantUnavailable:
            title = "Variant unavailable"
            message = "This conversation's agent variant is no longer available."
        case .unavailable:
            title = "Sharing unavailable"
            message = "The selected deployment can't mint share links right now."
        case .timeout:
            title = "Request timed out"
            message = "The request timed out. Nothing was copied; it is safe to try again."
        case .failed:
            title = "Couldn't create a share link"
            message = "Try again. If the problem continues, check the selected deployment."
        case .rateLimited:
            title = "Too many share links"
            message = "Wait a moment, then try again."
        }
        return ConversationSpaceShareAlertPayload(title: title, message: message)
    }
}
