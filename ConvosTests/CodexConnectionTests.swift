import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class CodexConnectionTests: XCTestCase {
    func testConfigurationRequiresWebSocketTokenAndAbsoluteWorkspace() throws {
        XCTAssertThrowsError(
            try CodexConnectionConfiguration(
                endpointText: "https://mac.local:4500",
                capabilityToken: "secret",
                workspacePath: "/Users/shane/project",
                sharesYourSpaceContext: true
            )
        )
        XCTAssertThrowsError(
            try CodexConnectionConfiguration(
                endpointText: "ws://mac.local:4500",
                capabilityToken: "",
                workspacePath: "/Users/shane/project",
                sharesYourSpaceContext: true
            )
        )
        XCTAssertThrowsError(
            try CodexConnectionConfiguration(
                endpointText: "ws://mac.local:4500",
                capabilityToken: "secret",
                workspacePath: "project",
                sharesYourSpaceContext: true
            )
        )

        let configuration = try CodexConnectionConfiguration(
            endpointText: " wss://codex.example.com/bridge ",
            capabilityToken: " secret ",
            workspacePath: " /Users/shane/project ",
            sharesYourSpaceContext: true
        )
        XCTAssertEqual(configuration.endpoint.absoluteString, "wss://codex.example.com/bridge")
        XCTAssertEqual(configuration.capabilityToken, "secret")
        XCTAssertEqual(configuration.workspacePath, "/Users/shane/project")
        XCTAssertTrue(configuration.allowsNetworkAccess)
    }

    func testPairingLinkBuildsAConnectionWithoutExposingManualFields() throws {
        let pairing = try CodexPairingLink(
            "convos://codex/connect?endpoint=ws%3A%2F%2F192.168.1.7%3A4500&token=abc123&workspace=%2FUsers%2Fshane%2FMy%20Project"
        )
        let configuration = try pairing.configuration(
            sharesYourSpaceContext: true,
            allowsNetworkAccess: true
        )

        XCTAssertEqual(configuration.endpoint.absoluteString, "ws://192.168.1.7:4500")
        XCTAssertEqual(configuration.capabilityToken, "abc123")
        XCTAssertEqual(configuration.workspacePath, "/Users/shane/My Project")
        XCTAssertTrue(configuration.sharesYourSpaceContext)
        XCTAssertTrue(configuration.allowsNetworkAccess)
    }

    func testPairingLinkRejectsUnexpectedSchemesAndRelativeWorkspaces() {
        XCTAssertThrowsError(
            try CodexPairingLink("https://example.com/connect?endpoint=ws://mac:4500&token=abc")
        )
        XCTAssertThrowsError(
            try CodexPairingLink("convos://codex/connect?endpoint=ws://mac:4500&token=abc&workspace=project")
        )
    }

    func testConnectionStoreKeepsTokenInKeychainAndResetsThreadWhenWorkspaceChanges() throws {
        let suiteName = "CodexConnectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychain()
        let first = try CodexConnectionConfiguration(
            endpointText: "ws://mac.local:4500",
            capabilityToken: "token-one",
            workspacePath: "/Users/shane/one",
            sharesYourSpaceContext: true
        )

        try CodexConnectionStore.save(first, defaults: defaults, keychain: keychain)
        CodexConnectionStore.saveThreadId("thread-1", defaults: defaults)

        XCTAssertEqual(
            CodexConnectionStore.configuration(defaults: defaults, keychain: keychain),
            first
        )
        XCTAssertEqual(CodexConnectionStore.threadId(defaults: defaults), "thread-1")
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: "your-space-codex-connection-v1")), encoding: .utf8)?.contains("token-one") == true)

        let moved = try CodexConnectionConfiguration(
            endpointText: "ws://mac.local:4500",
            capabilityToken: "token-two",
            workspacePath: "/Users/shane/two",
            sharesYourSpaceContext: true
        )
        try CodexConnectionStore.save(moved, defaults: defaults, keychain: keychain)

        XCTAssertNil(CodexConnectionStore.threadId(defaults: defaults))
        XCTAssertEqual(keychain.values["your-space-codex-capability-token-v1"], "token-two")
    }

    func testYourSpaceSnapshotLabelsContextAsDataAndIncludesRememberedDetails() throws {
        let field = YourSpaceRememberedField(
            category: .address,
            title: "Cabin",
            info: "3728 Bear Hollow Rd"
        )
        let briefing = YourSpaceBriefing(
            headline: "Nothing needs you right now.",
            attentionUpdates: [],
            recentUpdates: [],
            sourceCount: 2,
            peopleCount: 3
        )
        let snapshot = CodexYourSpaceSnapshot(
            briefing: briefing,
            contextItems: [YourSpaceContextItem(rememberedField: field)],
            conversationTitle: { _ in nil },
            senderName: { _ in nil }
        )

        let prompt = try snapshot.prompt(for: "Plan the drive")

        XCTAssertTrue(prompt.contains("Plan the drive"))
        XCTAssertTrue(prompt.contains("<convos_your_space_context>"))
        XCTAssertTrue(prompt.contains("untrusted user data"))
        XCTAssertTrue(prompt.contains("Cabin"))
        XCTAssertTrue(prompt.contains("3728 Bear Hollow Rd"))
        XCTAssertEqual(snapshot.totalContextItemCount, 1)
        XCTAssertEqual(snapshot.omittedContextItemCount, 0)
    }

    func testTurnAccumulatorReturnsFinalAnswerInsteadOfCommentary() throws {
        var accumulator = CodexTurnAccumulator(threadId: "thread-1", turnId: "turn-1")
        try accumulator.consume(agentMessage(text: "I’m checking that.", phase: "commentary"))
        try accumulator.consume(agentMessage(text: "Built it: https://example.com", phase: "final_answer"))
        try accumulator.consume(
            CodexRPCMessage(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string("turn-1"),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        XCTAssertTrue(accumulator.isComplete)
        XCTAssertEqual(accumulator.answer, "Built it: https://example.com")
    }

    func testTurnAccumulatorSurfacesFailedTurn() throws {
        var accumulator = CodexTurnAccumulator(threadId: "thread-1", turnId: "turn-1")
        XCTAssertThrowsError(
            try accumulator.consume(
                CodexRPCMessage(
                    method: "turn/completed",
                    params: .object([
                        "threadId": .string("thread-1"),
                        "turn": .object([
                            "id": .string("turn-1"),
                            "status": .string("failed"),
                            "error": .object(["message": .string("Workspace unavailable")]),
                        ]),
                    ])
                )
            )
        ) { error in
            XCTAssertEqual(error as? CodexConnectionError, .turnFailed("Workspace unavailable"))
        }
    }

    private func agentMessage(text: String, phase: String) -> CodexRPCMessage {
        CodexRPCMessage(
            method: "item/completed",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "item": .object([
                    "type": .string("agentMessage"),
                    "phase": .string(phase),
                    "text": .string(text),
                ]),
            ])
        )
    }
}

private final class TestKeychain: @unchecked Sendable, KeychainServiceProtocol {
    var values: [String: String] = [:]

    func saveString(_ value: String, account: String) throws {
        values[account] = value
    }

    func saveData(_ data: Data, account: String) throws {
        values[account] = String(data: data, encoding: .utf8)
    }

    func retrieveString(account: String) throws -> String? {
        values[account]
    }

    func retrieveData(account: String) throws -> Data? {
        values[account]?.data(using: .utf8)
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}
