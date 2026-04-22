@testable import ConvosCore
import Foundation
import Testing

/// Coverage for `SessionManager.shouldDisplayNotification(for:)` — the hook
/// `ConvosAppDelegate` consults before presenting an in-app banner. The
/// manager suppresses banners in two cases:
///
/// - The user is already viewing the target conversation (active conversation
///   id matches, fed via `.activeConversationChanged`).
/// - The user is on the conversations list, where the new-message indicator
///   already surfaces the update (fed via `setIsOnConversationsList`).
@Suite("SessionManager notification banner suppression")
struct SessionManagerNotificationSuppressionTests {
    @Test("Displays banner when user is on an unrelated screen")
    func displaysWhenIdle() async throws {
        let session = makeSession()

        let shouldDisplay = await session.shouldDisplayNotification(for: "conv-1")

        #expect(shouldDisplay == true)
    }

    @Test("Suppresses banner for the currently-active conversation")
    func suppressesActiveConversation() async throws {
        let session = makeSession()

        post(activeConversationId: "conv-1")

        let sameConversation = await session.shouldDisplayNotification(for: "conv-1")
        let otherConversation = await session.shouldDisplayNotification(for: "conv-2")

        #expect(sameConversation == false)
        #expect(otherConversation == true)
    }

    @Test("Resumes banners after active conversation clears")
    func resumesAfterActiveConversationClears() async throws {
        let session = makeSession()

        post(activeConversationId: "conv-1")
        post(activeConversationId: nil)

        let shouldDisplay = await session.shouldDisplayNotification(for: "conv-1")

        #expect(shouldDisplay == true)
    }

    @Test("Suppresses banners for any conversation while on the list")
    func suppressesOnConversationsList() async throws {
        let session = makeSession()

        session.setIsOnConversationsList(true)

        let first = await session.shouldDisplayNotification(for: "conv-1")
        let second = await session.shouldDisplayNotification(for: "conv-2")

        #expect(first == false)
        #expect(second == false)
    }

    @Test("Resumes banners after leaving the list")
    func resumesAfterLeavingList() async throws {
        let session = makeSession()

        session.setIsOnConversationsList(true)
        session.setIsOnConversationsList(false)

        let shouldDisplay = await session.shouldDisplayNotification(for: "conv-1")

        #expect(shouldDisplay == true)
    }

    @Test("List visibility suppresses banners even with no active conversation")
    func listVisibilityOverridesNoActive() async throws {
        let session = makeSession()

        post(activeConversationId: nil)
        session.setIsOnConversationsList(true)

        let shouldDisplay = await session.shouldDisplayNotification(for: "conv-1")

        #expect(shouldDisplay == false)
    }

    // MARK: - Helpers

    private func post(activeConversationId: String?) {
        let userInfo: [AnyHashable: Any] = activeConversationId.map { ["conversationId": $0] } ?? [:]
        NotificationCenter.default.post(
            name: .activeConversationChanged,
            object: nil,
            userInfo: userInfo
        )
    }

    private func makeSession() -> SessionManager {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        return SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock
        )
    }
}
