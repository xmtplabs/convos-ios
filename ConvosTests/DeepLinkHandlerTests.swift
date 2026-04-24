import ConvosCore
import XCTest
@testable import Convos

final class DeepLinkHandlerTests: XCTestCase {
    private var appUrlScheme: String {
        ConfigManager.shared.appUrlScheme
    }

    private var primaryDomain: String {
        ConfigManager.shared.associatedDomain
    }

    // MARK: - Connection Grant Deep Links (custom scheme)

    func testCustomSchemeConnectionGrant_ParsesServiceAndConversationId() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=abc123"))
        let destination = DeepLinkHandler.destination(for: url)

        guard case let .connectionGrant(service, conversationId) = destination else {
            XCTFail("Expected .connectionGrant, got \(String(describing: destination))")
            return
        }
        XCTAssertEqual(service, "google_calendar")
        XCTAssertEqual(conversationId, "abc123")
    }

    func testCustomSchemeConnectionGrant_MissingServiceReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?conversationId=abc123"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomSchemeConnectionGrant_MissingConversationIdReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomScheme_WrongHostFallsThroughToInviteParsing() throws {
        // Host "invite" with path "/grant" should NOT be parsed as a connection grant.
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://invite/grant?service=foo"))
        let destination = DeepLinkHandler.destination(for: url)
        // Either nil (not an invite either) or a joinConversation — but NOT connectionGrant.
        if case .connectionGrant = destination {
            XCTFail("Non-connections host should not produce a connectionGrant destination")
        }
    }

    func testCustomScheme_WrongPathReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/revoke?service=google_calendar&conversationId=abc123"))
        let destination = DeepLinkHandler.destination(for: url)
        if case .connectionGrant = destination {
            XCTFail("Unknown path under connections host should not be parsed as connectionGrant")
        }
    }

    // MARK: - Connection Grant Deep Links (https universal link)

    func testHttpsConnectionGrant_ParsesServiceAndConversationId() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/connections/grant?service=google_calendar&conversationId=abc123"))
        let destination = DeepLinkHandler.destination(for: url)

        guard case let .connectionGrant(service, conversationId) = destination else {
            XCTFail("Expected .connectionGrant, got \(String(describing: destination))")
            return
        }
        XCTAssertEqual(service, "google_calendar")
        XCTAssertEqual(conversationId, "abc123")
    }

    func testHttpsConnectionGrant_InvalidHostReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://evil.example.com/connections/grant?service=google_calendar&conversationId=abc"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    // MARK: - Invalid schemes

    func testInvalidSchemeReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/connections/grant?service=x&conversationId=y"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    // MARK: - Service allow-list

    func testUnknownServiceIsRejectedAtParseTime() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=evil_cloud&conversationId=abc123"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testEmptyServiceIsRejectedAtParseTime() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=&conversationId=abc123"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testKnownServiceIsAccepted() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_drive&conversationId=abc123"))
        guard case let .connectionGrant(service, conversationId) = DeepLinkHandler.destination(for: url) else {
            XCTFail("Expected .connectionGrant for known service")
            return
        }
        XCTAssertEqual(service, "google_drive")
        XCTAssertEqual(conversationId, "abc123")
    }

    // MARK: - Malicious conversationId

    func testConversationIdWithQuotesIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=abc%27%20OR%201%3D1"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testConversationIdWithPathTraversalIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=..%2Fetc%2Fpasswd"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testConversationIdWithSpacesIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=abc%20123"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testOverlyLongConversationIdIsRejected() throws {
        let longId = String(repeating: "a", count: 600)
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=\(longId)"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    // MARK: - ConversationsViewModel.handleURL validation

    @MainActor
    func testHandleURLDropsUnknownConversationId() throws {
        let knownConversation = Conversation.mock(id: "known-conv")
        let viewModel = ConversationsViewModel.preview(conversations: [knownConversation])
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=unknown-conv"))

        viewModel.handleURL(url)

        XCTAssertNil(viewModel.pendingGrantRequest, "Unknown conversationId should be dropped silently")
        XCTAssertNil(viewModel.selectedConversationId, "Selection should not change for unknown conversationId")
    }

    @MainActor
    func testHandleURLSetsPendingGrantForKnownConversation() throws {
        let knownConversation = Conversation.mock(id: "known-conv")
        let viewModel = ConversationsViewModel.preview(conversations: [knownConversation])
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=known-conv"))

        viewModel.handleURL(url)

        XCTAssertNotNil(viewModel.pendingGrantRequest)
        XCTAssertEqual(viewModel.pendingGrantRequest?.serviceId, "google_calendar")
        XCTAssertEqual(viewModel.pendingGrantRequest?.conversationId, "known-conv")
        XCTAssertEqual(viewModel.selectedConversationId, "known-conv")
    }

    @MainActor
    func testHandleURLDropsUnknownServiceEvenForKnownConversation() throws {
        let knownConversation = Conversation.mock(id: "known-conv")
        let viewModel = ConversationsViewModel.preview(conversations: [knownConversation])
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=evil_cloud&conversationId=known-conv"))

        viewModel.handleURL(url)

        XCTAssertNil(viewModel.pendingGrantRequest, "Unknown service should be rejected at parse time")
    }

    @MainActor
    func testHandleURLDropsMaliciousConversationId() throws {
        let knownConversation = Conversation.mock(id: "known-conv")
        let viewModel = ConversationsViewModel.preview(conversations: [knownConversation])
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=google_calendar&conversationId=abc%27%20OR%201%3D1"))

        viewModel.handleURL(url)

        XCTAssertNil(viewModel.pendingGrantRequest, "Malicious conversationId should be rejected")
    }
}
