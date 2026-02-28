import Foundation
import Testing

@testable import ConvosCore

@Suite("MCPAppContent Tests")
struct MCPAppContentTests {
    @Test("Create MCPAppContent with all fields")
    func createWithAllFields() {
        let content = MCPAppContent(
            resourceURI: "ui://weather/forecast",
            serverName: "Weather Server",
            displayMode: .inline,
            fallbackText: "Current weather: 72F, Sunny",
            toolName: "get_forecast",
            toolInput: "{\"location\":\"NYC\"}",
            toolResult: "{\"temp\":72,\"condition\":\"Sunny\"}"
        )

        #expect(content.resourceURI == "ui://weather/forecast")
        #expect(content.serverName == "Weather Server")
        #expect(content.displayMode == .inline)
        #expect(content.fallbackText == "Current weather: 72F, Sunny")
        #expect(content.toolName == "get_forecast")
        #expect(content.toolInput == "{\"location\":\"NYC\"}")
        #expect(content.toolResult == "{\"temp\":72,\"condition\":\"Sunny\"}")
    }

    @Test("Create MCPAppContent with defaults")
    func createWithDefaults() {
        let content = MCPAppContent(
            resourceURI: "ui://app/main",
            serverName: "Test Server",
            fallbackText: "An interactive app"
        )

        #expect(content.displayMode == .inline)
        #expect(content.toolName == nil)
        #expect(content.toolInput == nil)
        #expect(content.toolResult == nil)
    }

    @Test("MCPAppContent Codable round-trip")
    func codableRoundTrip() throws {
        let original = MCPAppContent(
            resourceURI: "ui://test/resource",
            serverName: "Test Server",
            displayMode: .modal,
            fallbackText: "Fallback text",
            toolName: "test_tool",
            toolInput: "{\"key\":\"value\"}",
            toolResult: "{\"result\":true}"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MCPAppContent.self, from: data)

        #expect(decoded == original)
    }

    @Test("MCPAppContent Codable round-trip with nil optionals")
    func codableRoundTripNilOptionals() throws {
        let original = MCPAppContent(
            resourceURI: "ui://app/main",
            serverName: "Server",
            fallbackText: "Fallback"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPAppContent.self, from: data)

        #expect(decoded == original)
        #expect(decoded.toolName == nil)
        #expect(decoded.toolInput == nil)
        #expect(decoded.toolResult == nil)
    }

    @Test("MCPAppContent equality")
    func equality() {
        let a = MCPAppContent(
            resourceURI: "ui://a", serverName: "S", fallbackText: "F"
        )
        let b = MCPAppContent(
            resourceURI: "ui://a", serverName: "S", fallbackText: "F"
        )
        let c = MCPAppContent(
            resourceURI: "ui://b", serverName: "S", fallbackText: "F"
        )

        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("MCPAppDisplayMode Tests")
struct MCPAppDisplayModeTests {
    @Test("All display modes encode correctly")
    func allDisplayModes() throws {
        let modes: [MCPAppDisplayMode] = [.inline, .modal, .panel, .popover]
        let expected = ["inline", "modal", "panel", "popover"]

        for (mode, expectedString) in zip(modes, expected) {
            let data = try JSONEncoder().encode(mode)
            let string = String(data: data, encoding: .utf8)
            #expect(string == "\"\(expectedString)\"")
        }
    }

    @Test("Display modes decode correctly")
    func decodeModes() throws {
        let decoder = JSONDecoder()
        let inline = try decoder.decode(MCPAppDisplayMode.self, from: "\"inline\"".data(using: .utf8)!)
        let modal = try decoder.decode(MCPAppDisplayMode.self, from: "\"modal\"".data(using: .utf8)!)

        #expect(inline == .inline)
        #expect(modal == .modal)
    }
}

@Suite("MessageContent MCP App Tests")
struct MessageContentMCPAppTests {
    @Test("MessageContent mcpApp case Codable round-trip")
    func mcpAppCodableRoundTrip() throws {
        let mcpApp = MCPAppContent(
            resourceURI: "ui://test/app",
            serverName: "Test",
            displayMode: .panel,
            fallbackText: "Interactive test app"
        )
        let content = MessageContent.mcpApp(mcpApp)

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: data)

        #expect(decoded == content)
    }

    @Test("MessageContent mcpApp shows in messages list")
    func mcpAppShowsInMessagesList() {
        let content = MessageContent.mcpApp(
            MCPAppContent(resourceURI: "ui://x", serverName: "S", fallbackText: "F")
        )
        #expect(content.showsInMessagesList == true)
    }

    @Test("MessageContent mcpApp is not update")
    func mcpAppIsNotUpdate() {
        let content = MessageContent.mcpApp(
            MCPAppContent(resourceURI: "ui://x", serverName: "S", fallbackText: "F")
        )
        #expect(content.isUpdate == false)
    }

    @Test("MessageContent mcpApp is not emoji")
    func mcpAppIsNotEmoji() {
        let content = MessageContent.mcpApp(
            MCPAppContent(resourceURI: "ui://x", serverName: "S", fallbackText: "F")
        )
        #expect(content.isEmoji == false)
    }

    @Test("MessageContent mcpApp shows sender")
    func mcpAppShowsSender() {
        let content = MessageContent.mcpApp(
            MCPAppContent(resourceURI: "ui://x", serverName: "S", fallbackText: "F")
        )
        #expect(content.showsSender == true)
    }

    @Test("MessageContent mcpApp is not attachment")
    func mcpAppIsNotAttachment() {
        let content = MessageContent.mcpApp(
            MCPAppContent(resourceURI: "ui://x", serverName: "S", fallbackText: "F")
        )
        #expect(content.isAttachment == false)
    }

    @Test("Backwards compatibility: existing content types decode without mcpApp")
    func backwardsCompatibility() throws {
        let textContent = MessageContent.text("Hello world")
        let data = try JSONEncoder().encode(textContent)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
        #expect(decoded == textContent)

        let emojiContent = MessageContent.emoji("👍")
        let emojiData = try JSONEncoder().encode(emojiContent)
        let decodedEmoji = try JSONDecoder().decode(MessageContent.self, from: emojiData)
        #expect(decodedEmoji == emojiContent)
    }
}

@Suite("MessageContentType MCP App Tests")
struct MessageContentTypeMCPAppTests {
    @Test("mcpApp content type raw value")
    func mcpAppRawValue() {
        #expect(MessageContentType.mcpApp.rawValue == "mcpApp")
    }

    @Test("mcpApp content type marks conversation as unread")
    func mcpAppMarksAsUnread() {
        #expect(MessageContentType.mcpApp.marksConversationAsUnread == true)
    }

    @Test("mcpApp content type Codable round-trip")
    func mcpAppCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(MessageContentType.mcpApp)
        let decoded = try JSONDecoder().decode(MessageContentType.self, from: data)
        #expect(decoded == .mcpApp)
    }
}
