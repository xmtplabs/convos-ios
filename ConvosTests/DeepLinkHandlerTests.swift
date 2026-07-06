@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class DeepLinkHandlerTests: XCTestCase {
    private var appUrlScheme: String {
        ConfigManager.shared.appUrlScheme
    }

    private var primaryDomain: String {
        ConfigManager.shared.associatedDomain
    }

    private let sampleTemplateId: String = "200e27dc-badc-429f-a431-b01b0281ec95"

    // MARK: - Connection Grant Deep Links (custom scheme)

    func testCustomSchemeConnectionGrant_ParsesServiceAndConversationId() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=abc123"))
        let destination = DeepLinkHandler.destination(for: url)

        guard case let .connectionGrant(service, conversationId) = destination else {
            XCTFail("Expected .connectionGrant, got \(String(describing: destination))")
            return
        }
        XCTAssertEqual(service, "googlecalendar")
        XCTAssertEqual(conversationId, "abc123")
    }

    func testCustomSchemeConnectionGrant_MissingServiceReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?conversationId=abc123"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomSchemeConnectionGrant_MissingConversationIdReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar"))
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
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/revoke?service=googlecalendar&conversationId=abc123"))
        let destination = DeepLinkHandler.destination(for: url)
        if case .connectionGrant = destination {
            XCTFail("Unknown path under connections host should not be parsed as connectionGrant")
        }
    }

    // MARK: - Connection Grant Deep Links (https universal link)

    func testHttpsConnectionGrant_ParsesServiceAndConversationId() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/connections/grant?service=googlecalendar&conversationId=abc123"))
        let destination = DeepLinkHandler.destination(for: url)

        guard case let .connectionGrant(service, conversationId) = destination else {
            XCTFail("Expected .connectionGrant, got \(String(describing: destination))")
            return
        }
        XCTAssertEqual(service, "googlecalendar")
        XCTAssertEqual(conversationId, "abc123")
    }

    func testHttpsConnectionGrant_InvalidHostReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://evil.example.com/connections/grant?service=googlecalendar&conversationId=abc"))
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
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googledrive&conversationId=abc123"))
        guard case let .connectionGrant(service, conversationId) = DeepLinkHandler.destination(for: url) else {
            XCTFail("Expected .connectionGrant for known service")
            return
        }
        XCTAssertEqual(service, "googledrive")
        XCTAssertEqual(conversationId, "abc123")
    }

    // MARK: - Malicious conversationId

    func testConversationIdWithQuotesIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=abc%27%20OR%201%3D1"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testConversationIdWithPathTraversalIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=..%2Fetc%2Fpasswd"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testConversationIdWithSpacesIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=abc%20123"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testOverlyLongConversationIdIsRejected() throws {
        let longId = String(repeating: "a", count: 600)
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=\(longId)"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    // MARK: - Agent template deep links (custom scheme)

    func testCustomSchemeAgentTemplate_ParsesTemplateId() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/\(sampleTemplateId)"))
        let destination = DeepLinkHandler.destination(for: url)

        guard case let .agentTemplate(templateId) = destination else {
            XCTFail("Expected .agentTemplate, got \(String(describing: destination))")
            return
        }
        XCTAssertEqual(templateId, sampleTemplateId)
    }

    func testCustomSchemeAgentTemplate_UppercaseTemplateIdAccepted() throws {
        // The backend treats UUIDs case-insensitively per its uuidPattern regex;
        // mirror that on the client so a recipient on a slightly-quirky email
        // client that uppercased the URL doesn't get a 404.
        let uppercased = sampleTemplateId.uppercased()
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/\(uppercased)"))
        guard case let .agentTemplate(templateId) = DeepLinkHandler.destination(for: url) else {
            XCTFail("Expected .agentTemplate for uppercase UUID")
            return
        }
        XCTAssertEqual(templateId, uppercased)
    }

    func testCustomSchemeAgentTemplate_MissingIdReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomSchemeAgentTemplate_MalformedIdReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/not-a-uuid"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomSchemeAgentTemplate_HashedSlugRejected() throws {
        // V1 handles UUID template ids only. The pretty `<base>.<hash>`
        // slug form the backend resolver also accepts is a follow-up;
        // reject it for now rather than route to a destination we can't
        // yet resolve client-side.
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/anchor.pnw1o"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomSchemeAgentTemplate_ExtraPathSegmentsRejected() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/\(sampleTemplateId)/extra"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testCustomSchemeAgentTemplate_WrongHostReturnsNil() throws {
        // `convos://templates/<id>` (plural) is not a route we recognise.
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://templates/\(sampleTemplateId)"))
        let destination = DeepLinkHandler.destination(for: url)
        if case .agentTemplate = destination {
            XCTFail("Unknown host should not produce an .agentTemplate destination")
        }
    }

    // MARK: - Agent template deep links (https universal link)

    func testUniversalLinkAgentTemplate_ParsesTemplateId() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/template/\(sampleTemplateId)"))
        let destination = DeepLinkHandler.destination(for: url)

        guard case let .agentTemplate(templateId) = destination else {
            XCTFail("Expected .agentTemplate, got \(String(describing: destination))")
            return
        }
        XCTAssertEqual(templateId, sampleTemplateId)
    }

    func testUniversalLinkAgentTemplate_UppercaseTemplateIdAccepted() throws {
        let uppercased = sampleTemplateId.uppercased()
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/template/\(uppercased)"))
        guard case let .agentTemplate(templateId) = DeepLinkHandler.destination(for: url) else {
            XCTFail("Expected .agentTemplate for uppercase UUID")
            return
        }
        XCTAssertEqual(templateId, uppercased)
    }

    func testUniversalLinkAgentTemplate_InvalidHostReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://evil.example.com/template/\(sampleTemplateId)"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testUniversalLinkAgentTemplate_MissingIdReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/template/"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testUniversalLinkAgentTemplate_MalformedIdReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/template/not-a-uuid"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    func testUniversalLinkAgentTemplate_ExtraPathSegmentsRejected() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/template/\(sampleTemplateId)/extra"))
        XCTAssertNil(DeepLinkHandler.destination(for: url))
    }

    // MARK: - DeepLinkHandler.agentTemplateId(from:)

    func testAgentTemplateId_ReturnsTemplateIdForTemplateURL() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/\(sampleTemplateId)"))
        XCTAssertEqual(DeepLinkHandler.agentTemplateId(from: url), sampleTemplateId)
    }

    func testAgentTemplateId_ReturnsTemplateIdForUniversalLinkURL() throws {
        let url = try XCTUnwrap(URL(string: "https://\(primaryDomain)/template/\(sampleTemplateId)"))
        XCTAssertEqual(DeepLinkHandler.agentTemplateId(from: url), sampleTemplateId)
    }

    func testAgentTemplateId_ReturnsNilForNonTemplateDeepLink() throws {
        // A non-template deep link (here a connection grant) must not
        // resolve to a template id - the QR scanner relies on this so a
        // scanned conversation invite keeps routing through the invite
        // path unchanged.
        let url = try XCTUnwrap(
            URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=abc123")
        )
        XCTAssertNil(DeepLinkHandler.agentTemplateId(from: url))
    }

    func testAgentTemplateId_ReturnsNilForMalformedId() throws {
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://template/not-a-uuid"))
        XCTAssertNil(DeepLinkHandler.agentTemplateId(from: url))
    }

    // MARK: - ConversationsViewModel.handleURL validation

    @MainActor
    func testHandleURLDropsUnknownConversationId() throws {
        let knownConversation = Conversation.mock(id: "known-conv")
        let viewModel = ConversationsViewModel.preview(conversations: [knownConversation])
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=unknown-conv"))

        viewModel.handleURL(url)

        XCTAssertNil(viewModel.pendingGrantRequest, "Unknown conversationId should be dropped silently")
        XCTAssertNil(viewModel.selectedConversationId, "Selection should not change for unknown conversationId")
    }

    @MainActor
    func testHandleURLSetsPendingGrantForKnownConversation() throws {
        let knownConversation = Conversation.mock(id: "known-conv")
        let viewModel = ConversationsViewModel.preview(conversations: [knownConversation])
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=known-conv"))

        viewModel.handleURL(url)

        XCTAssertNotNil(viewModel.pendingGrantRequest)
        XCTAssertEqual(viewModel.pendingGrantRequest?.serviceId, "googlecalendar")
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
        let url = try XCTUnwrap(URL(string: "\(appUrlScheme)://connections/grant?service=googlecalendar&conversationId=abc%27%20OR%201%3D1"))

        viewModel.handleURL(url)

        XCTAssertNil(viewModel.pendingGrantRequest, "Malicious conversationId should be rejected")
    }
}
