import ConvosConnections
import Foundation
import Observation
import UIKit

/// Example implementation of `ConfirmationHandling`.
///
/// When the manager's always-confirm gate fires, it `await`s our `confirm(_:)`. We stash
/// the request (plus its completion continuation) on the main actor, let SwiftUI observe
/// `pendingRequest`, and wait for the user to tap Approve or Deny. `resolve(_:)` resumes
/// the continuation, which causes the manager's 6-step routing chain to continue.
///
/// Returns `.cannotPresent` immediately when the app is not active — the manager surfaces
/// that as `requiresConfirmation`, signalling the agent to retry when the user's back.
@MainActor
@Observable
final class ExampleConfirmationHandler: ConfirmationHandling {
    private(set) var pendingRequest: ConfirmationRequest?
    private var continuation: CheckedContinuation<ConfirmationDecision, Never>?

    nonisolated func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else {
                    continuation.resume(returning: .cannotPresent)
                    return
                }
                // If a prior request is still pending (shouldn't happen in v1; manager calls
                // confirm once per invocation), deny the old one so the new one takes over.
                if let previous = self.continuation {
                    previous.resume(returning: .denied)
                }
                self.continuation = continuation
                self.pendingRequest = request
            }
        }
    }

    func resolve(_ decision: ConfirmationDecision) {
        let active = continuation
        continuation = nil
        pendingRequest = nil
        active?.resume(returning: decision)
    }
}
