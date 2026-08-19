import ConvosCore
import ConvosMetrics
import Foundation
import Observation

/// Resolves the conversation the Space Home is a view of, and holds the
/// conversation view model built from it.
///
/// Provisioning runs at most once per launch and only when there is nothing to
/// find - see `PersonalSpaceService`. Until it lands the Space Home has no
/// conversation to render, which is a real state and not an error: a first
/// launch reaches this screen before the warm cache has anything in it.
@Observable
@MainActor
final class SpaceHomeViewModel {
    private(set) var space: Conversation?
    private(set) var spaceViewModel: ConversationViewModel?
    /// Set when provisioning gave up. The screen keeps its chrome and says so
    /// rather than sitting on a spinner that will never resolve.
    private(set) var failure: String?

    private let session: any SessionManagerProtocol
    private let coreActions: any CoreActions
    private let personalSpaceService: PersonalSpaceService

    init(session: any SessionManagerProtocol, coreActions: any CoreActions) {
        self.session = session
        self.coreActions = coreActions
        self.personalSpaceService = PersonalSpaceService(session: session)
        // Paint on the first frame when the Space already exists, which is
        // every launch after the first. Waiting for the async path would blank
        // the screen for a beat on a screen that is the app's front door.
        if let existing = personalSpaceService.existingPersonalSpace() {
            adopt(existing)
        }
    }

    func load() async {
        do {
            let space = try await personalSpaceService.personalSpace()
            failure = nil
            adopt(space)
        } catch {
            Log.error("Space Home: could not resolve the personal Space: \(error)")
            // Only surface the failure when there is nothing on screen. A
            // refresh that fails behind an already-rendered Space is not worth
            // replacing it with an error.
            if space == nil {
                failure = "Your Space isn't ready yet."
            }
        }
    }

    /// Rebuilds the conversation view model only when the identity changes, so
    /// a refresh that returns the same Space doesn't tear down a live
    /// transcript and its scroll position.
    private func adopt(_ conversation: Conversation) {
        space = conversation
        guard spaceViewModel?.conversation.id != conversation.id else { return }
        spaceViewModel = ConversationViewModel.createSync(
            conversation: conversation,
            session: session,
            coreActions: coreActions
        )
    }
}
