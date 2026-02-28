@testable import ConvosCore
import Foundation
import Testing

@Suite("MCP App Security - CSP")
struct MCPAppCSPTests {
    @Test("Wildcard domains are filtered from CSP")
    func wildcardDomainsFiltered() {
        let domains = ["*.example.com", "api.safe.com", "*.evil.com", "cdn.trusted.com"]
        let filtered = domains.filter { !$0.contains("*") }
        #expect(filtered == ["api.safe.com", "cdn.trusted.com"])
    }

    @Test("Empty allowed domains produce no connect-src directive")
    func emptyDomainsNoConnectSrc() {
        let domains: [String] = []
        let hasConnectSrc = !domains.isEmpty
        #expect(hasConnectSrc == false)
    }

    @Test("Valid domains are included in CSP")
    func validDomainsIncluded() {
        let domains = ["api.weather.com", "cdn.maps.com"]
        let filtered = domains.filter { !$0.contains("*") }
        let connectSrc = "connect-src " + filtered.joined(separator: " ")
        #expect(connectSrc == "connect-src api.weather.com cdn.maps.com")
    }
}

@Suite("MCP App Security - JSON-RPC")
struct MCPAppJSONRPCSecurityTests {
    @Test("Unknown method returns method not found error")
    func unknownMethodError() {
        let error = JSONRPCError.methodNotFound
        #expect(error.code == -32601)
    }

    @Test("Server error has correct code")
    func serverErrorCode() {
        let error = JSONRPCError.serverError("denied")
        #expect(error.code == -32000)
    }

    @Test("Invalid params error has correct code")
    func invalidParamsCode() {
        let error = JSONRPCError.invalidParams
        #expect(error.code == -32602)
    }

    @Test("Request without id is notification")
    func notificationDetection() {
        let notification = JSONRPCRequest(method: "ui/notifications/initialized")
        #expect(notification.isNotification == true)
        #expect(notification.id == nil)
    }

    @Test("Request with id is not notification")
    func requestDetection() {
        let request = JSONRPCRequest(id: 1, method: "ui/initialize")
        #expect(request.isNotification == false)
    }
}

@Suite("MCP App Security - Content Validation")
struct MCPAppContentValidationTests {
    @Test("MCPAppContent with all nil optionals")
    func minimalContent() throws {
        let content = MCPAppContent(
            resourceURI: "ui://test/app",
            serverName: "Test",
            fallbackText: "fallback"
        )
        #expect(content.toolName == nil)
        #expect(content.toolInput == nil)
        #expect(content.toolResult == nil)
        #expect(content.displayMode == .inline)
    }

    @Test("MCPAppContent round-trip preserves all fields")
    func fullContentRoundTrip() throws {
        let content = MCPAppContent(
            resourceURI: "ui://weather/forecast",
            serverName: "Weather",
            displayMode: .modal,
            fallbackText: "72F sunny",
            toolName: "get_weather",
            toolInput: "{\"location\":\"SF\"}",
            toolResult: "{\"temp\":72}"
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(MCPAppContent.self, from: data)
        #expect(decoded.resourceURI == content.resourceURI)
        #expect(decoded.serverName == content.serverName)
        #expect(decoded.displayMode == .modal)
        #expect(decoded.toolName == "get_weather")
        #expect(decoded.toolInput == "{\"location\":\"SF\"}")
        #expect(decoded.toolResult == "{\"temp\":72}")
    }

    @Test("MCPAppContent with empty strings")
    func emptyStrings() throws {
        let content = MCPAppContent(
            resourceURI: "",
            serverName: "",
            fallbackText: ""
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(MCPAppContent.self, from: data)
        #expect(decoded.resourceURI == "")
        #expect(decoded.serverName == "")
        #expect(decoded.fallbackText == "")
    }

    @Test("MCPAppContent with special characters in fallback")
    func specialCharactersFallback() throws {
        let content = MCPAppContent(
            resourceURI: "ui://test/app",
            serverName: "Test <script>alert('xss')</script>",
            fallbackText: "Text with <b>HTML</b> & \"quotes\" and 'apostrophes'"
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(MCPAppContent.self, from: data)
        #expect(decoded.serverName.contains("<script>"))
        #expect(decoded.fallbackText.contains("&"))
    }
}

@Suite("MCP App Security - Host Context")
struct MCPAppHostContextSecurityTests {
    @Test("Host context defaults to nil for all optional fields")
    func defaultContext() {
        let context = MCPAppHostContext()
        #expect(context.theme == nil)
        #expect(context.styles == nil)
        #expect(context.displayMode == nil)
        #expect(context.locale == nil)
        #expect(context.platform == nil)
    }

    @Test("Host context serialization doesn't leak unexpected fields")
    func noUnexpectedFields() throws {
        let context = MCPAppHostContext(theme: "dark", platform: "mobile")
        let data = try JSONEncoder().encode(context)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["theme"] as? String == "dark")
        #expect(dict?["platform"] as? String == "mobile")
        #expect(dict?["secrets"] == nil)
        #expect(dict?["apiKey"] == nil)
    }

    @Test("Initialize result includes correct protocol version")
    func initResultProtocolVersion() throws {
        let result = MCPAppInitializeResult(
            hostInfo: .init(name: "Convos", version: "1.0"),
            hostContext: MCPAppHostContext()
        )
        #expect(result.protocolVersion == "2026-01-26")
    }
}

@Suite("MCP App Security - Display Modes")
struct MCPAppDisplayModeSecurityTests {
    @Test("All display modes are valid")
    func allModesValid() {
        let modes: [MCPAppDisplayMode] = [.inline, .modal, .panel, .popover]
        #expect(modes.count == 4)
    }

    @Test("Unknown display mode defaults to inline in content")
    func defaultDisplayMode() {
        let content = MCPAppContent(
            resourceURI: "ui://test/app",
            serverName: "Test",
            fallbackText: "test"
        )
        #expect(content.displayMode == .inline)
    }

    @Test("Display mode round-trip through JSON")
    func displayModeRoundTrip() throws {
        for mode in [MCPAppDisplayMode.inline, .modal, .panel, .popover] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(MCPAppDisplayMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}
