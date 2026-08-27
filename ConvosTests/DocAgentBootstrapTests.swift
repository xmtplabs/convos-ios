@testable import Convos
import ConvosCore
import Foundation
import Testing

@MainActor
struct DocAgentBootstrapTests {
    @Test("fresh bind bootstraps once, relaunch stays quiet, and reset enables a new agent")
    func bootstrapLifecycle() async throws {
        let suiteName = "DocAgentBootstrapTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = MockInboxesService()
        let pendingOriginKey = DocExperienceViewModel.storageKey(
            DocExperienceViewModel.bootstrapPendingOriginConversationIdComponent,
            session: session
        )
        let sentBindingsKey = DocExperienceViewModel.storageKey(
            DocExperienceViewModel.bootstrapSentBindingsComponent,
            session: session
        )
        var sentMessages: [String] = []
        defaults.set("origin-one", forKey: pendingOriginKey)

        let firstLaunch = DocAgentBootstrapSender()
        let firstResult = try await firstLaunch.sendIfNeeded(
            binding: .init(
                originConversationId: "origin-one",
                agentInboxId: "agent-one",
                dmConversationId: "dm-one"
            ),
            defaults: defaults,
            pendingOriginKey: pendingOriginKey,
            sentBindingsKey: sentBindingsKey
        ) { text, _ in
            sentMessages.append(text)
        }
        let duplicateResult = try await firstLaunch.sendIfNeeded(
            binding: .init(
                originConversationId: "origin-one",
                agentInboxId: "agent-one",
                dmConversationId: "dm-one"
            ),
            defaults: defaults,
            pendingOriginKey: pendingOriginKey,
            sentBindingsKey: sentBindingsKey
        ) { text, _ in
            sentMessages.append(text)
        }

        let relaunched = DocAgentBootstrapSender()
        let relaunchResult = try await relaunched.sendIfNeeded(
            binding: .init(
                originConversationId: "origin-one",
                agentInboxId: "agent-one",
                dmConversationId: "dm-one"
            ),
            defaults: defaults,
            pendingOriginKey: pendingOriginKey,
            sentBindingsKey: sentBindingsKey
        ) { text, _ in
            sentMessages.append(text)
        }

        #expect(firstResult == .sent)
        #expect(duplicateResult == .notPending)
        #expect(relaunchResult == .notPending)
        #expect(sentMessages == [#"⟦req⟧{"v":1,"t":"bootstrap"}"#])

        DocExperienceViewModel.resetAgentBinding(session: session, defaults: defaults)
        #expect(defaults.object(forKey: pendingOriginKey) == nil)
        #expect(defaults.object(forKey: sentBindingsKey) == nil)
        defaults.set("origin-two", forKey: pendingOriginKey)
        let resetLaunch = DocAgentBootstrapSender()
        let resetResult = try await resetLaunch.sendIfNeeded(
            binding: .init(
                originConversationId: "origin-two",
                agentInboxId: "agent-two",
                dmConversationId: "dm-two"
            ),
            defaults: defaults,
            pendingOriginKey: pendingOriginKey,
            sentBindingsKey: sentBindingsKey
        ) { text, _ in
            sentMessages.append(text)
        }

        #expect(resetResult == .sent)
        #expect(sentMessages == [
            #"⟦req⟧{"v":1,"t":"bootstrap"}"#,
            #"⟦req⟧{"v":1,"t":"bootstrap"}"#,
        ])
    }
}
