@testable import ConvosCore
import Foundation
import Testing

@Suite("MCPServerConfiguration Tests")
struct MCPServerConfigurationTests {

    @Test("HTTP configuration initializes correctly")
    func testHTTPConfiguration() {
        let url = URL(string: "https://example.com/mcp")!
        let config = MCPServerConfiguration(
            id: "test-server",
            name: "Test Server",
            transportType: .http(endpoint: url)
        )

        #expect(config.id == "test-server")
        #expect(config.name == "Test Server")
        #expect(config.supportsUI == false)

        if case .http(let endpoint) = config.transportType {
            #expect(endpoint == url)
        } else {
            Issue.record("Expected HTTP transport type")
        }
    }

    @Test("Stdio configuration initializes correctly")
    func testStdioConfiguration() {
        let config = MCPServerConfiguration(
            id: "local-server",
            name: "Local Server",
            transportType: .stdio(command: "/usr/bin/mcp-server", arguments: ["--port", "8080"])
        )

        #expect(config.id == "local-server")
        #expect(config.name == "Local Server")

        if case .stdio(let command, let arguments) = config.transportType {
            #expect(command == "/usr/bin/mcp-server")
            #expect(arguments == ["--port", "8080"])
        } else {
            Issue.record("Expected stdio transport type")
        }
    }

    @Test("Configuration with UI support")
    func testUISupport() {
        let config = MCPServerConfiguration(
            id: "ui-server",
            name: "UI Server",
            transportType: .http(endpoint: URL(string: "https://example.com")!),
            supportsUI: true
        )

        #expect(config.supportsUI == true)
    }

    @Test("Configuration conforms to Identifiable")
    func testIdentifiable() {
        let config = MCPServerConfiguration(
            id: "my-id",
            name: "Server",
            transportType: .http(endpoint: URL(string: "https://example.com")!)
        )

        #expect(config.id == "my-id")
    }

    @Test("Configuration equality")
    func testEquality() {
        let url = URL(string: "https://example.com")!
        let config1 = MCPServerConfiguration(id: "a", name: "A", transportType: .http(endpoint: url))
        let config2 = MCPServerConfiguration(id: "a", name: "A", transportType: .http(endpoint: url))
        let config3 = MCPServerConfiguration(id: "b", name: "B", transportType: .http(endpoint: url))

        #expect(config1 == config2)
        #expect(config1 != config3)
    }

    @Test("Configuration is Codable")
    func testCodable() throws {
        let url = URL(string: "https://example.com/mcp")!
        let original = MCPServerConfiguration(
            id: "test",
            name: "Test",
            transportType: .http(endpoint: url),
            supportsUI: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: data)

        #expect(decoded == original)
    }
}

@Suite("MCPConnectionState Tests")
struct MCPConnectionStateTests {

    @Test("Disconnected state equality")
    func testDisconnectedEquality() {
        #expect(MCPConnectionState.disconnected == MCPConnectionState.disconnected)
    }

    @Test("Connecting state equality")
    func testConnectingEquality() {
        #expect(MCPConnectionState.connecting == MCPConnectionState.connecting)
    }

    @Test("Connected state equality")
    func testConnectedEquality() {
        let state1 = MCPConnectionState.connected(serverName: "A", protocolVersion: "1.0")
        let state2 = MCPConnectionState.connected(serverName: "A", protocolVersion: "1.0")
        let state3 = MCPConnectionState.connected(serverName: "B", protocolVersion: "1.0")

        #expect(state1 == state2)
        #expect(state1 != state3)
    }

    @Test("Different states are not equal")
    func testDifferentStatesNotEqual() {
        #expect(MCPConnectionState.disconnected != MCPConnectionState.connecting)
        #expect(MCPConnectionState.connecting != MCPConnectionState.connected(serverName: "A", protocolVersion: "1.0"))
    }
}

@Suite("MCPServerCapabilities Tests")
struct MCPServerCapabilitiesTests {

    @Test("Default capabilities are all false")
    func testDefaults() {
        let caps = MCPServerCapabilities()

        #expect(caps.supportsResources == false)
        #expect(caps.supportsTools == false)
        #expect(caps.supportsPrompts == false)
        #expect(caps.supportsUI == false)
    }

    @Test("Custom capabilities")
    func testCustomCapabilities() {
        let caps = MCPServerCapabilities(
            supportsResources: true,
            supportsTools: true,
            supportsPrompts: false,
            supportsUI: true
        )

        #expect(caps.supportsResources == true)
        #expect(caps.supportsTools == true)
        #expect(caps.supportsPrompts == false)
        #expect(caps.supportsUI == true)
    }
}

@Suite("MCPDiscoveredResource Tests")
struct MCPDiscoveredResourceTests {

    @Test("UI resource detection")
    func testIsUIResource() {
        let uiResource = MCPDiscoveredResource(
            uri: "ui://weather-app/main",
            name: "Weather App"
        )
        let regularResource = MCPDiscoveredResource(
            uri: "file:///data.json",
            name: "Data File"
        )

        #expect(uiResource.isUIResource == true)
        #expect(regularResource.isUIResource == false)
    }

    @Test("Resource ID is URI")
    func testResourceId() {
        let resource = MCPDiscoveredResource(
            uri: "ui://test/resource",
            name: "Test"
        )

        #expect(resource.id == "ui://test/resource")
    }

    @Test("Resource with all fields")
    func testAllFields() {
        let resource = MCPDiscoveredResource(
            uri: "ui://app/view",
            name: "App View",
            title: "My App",
            description: "A test app",
            mimeType: "text/html"
        )

        #expect(resource.name == "App View")
        #expect(resource.title == "My App")
        #expect(resource.description == "A test app")
        #expect(resource.mimeType == "text/html")
    }
}

@Suite("MCPConnectionManager Tests")
struct MCPConnectionManagerTests {

    @Test("Initial state is disconnected")
    func testInitialState() async {
        let config = MCPServerConfiguration(
            id: "test",
            name: "Test",
            transportType: .http(endpoint: URL(string: "https://example.com")!)
        )
        let manager = MCPConnectionManager(configuration: config)

        let state = await manager.state
        #expect(state == .disconnected)

        let capabilities = await manager.serverCapabilities
        #expect(capabilities == nil)

        let resources = await manager.discoveredResources
        #expect(resources.isEmpty)
    }

    @Test("Stdio transport throws on iOS")
    func testStdioThrows() async {
        let config = MCPServerConfiguration(
            id: "local",
            name: "Local",
            transportType: .stdio(command: "/usr/bin/server", arguments: [])
        )
        let manager = MCPConnectionManager(configuration: config)

        do {
            try await manager.connect()
            Issue.record("Expected stdioNotSupportedOnIOS error")
        } catch let error as MCPConnectionError {
            if case .stdioNotSupportedOnIOS = error {
                // expected
            } else {
                Issue.record("Expected stdioNotSupportedOnIOS, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let state = await manager.state
        #expect(state == .failed("Stdio transport is not supported on iOS"))
    }

    @Test("listResources throws when not connected")
    func testListResourcesNotConnected() async {
        let config = MCPServerConfiguration(
            id: "test",
            name: "Test",
            transportType: .http(endpoint: URL(string: "https://example.com")!)
        )
        let manager = MCPConnectionManager(configuration: config)

        do {
            _ = try await manager.listResources()
            Issue.record("Expected notConnected error")
        } catch let error as MCPConnectionError {
            if case .notConnected = error {
                // expected
            } else {
                Issue.record("Expected notConnected, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("readResource throws when not connected")
    func testReadResourceNotConnected() async {
        let config = MCPServerConfiguration(
            id: "test",
            name: "Test",
            transportType: .http(endpoint: URL(string: "https://example.com")!)
        )
        let manager = MCPConnectionManager(configuration: config)

        do {
            _ = try await manager.readResource(uri: "ui://test")
            Issue.record("Expected notConnected error")
        } catch let error as MCPConnectionError {
            if case .notConnected = error {
                // expected
            } else {
                Issue.record("Expected notConnected, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("disconnect from disconnected state is no-op")
    func testDisconnectFromDisconnected() async {
        let config = MCPServerConfiguration(
            id: "test",
            name: "Test",
            transportType: .http(endpoint: URL(string: "https://example.com")!)
        )
        let manager = MCPConnectionManager(configuration: config)

        await manager.disconnect()

        let state = await manager.state
        #expect(state == .disconnected)
    }
}

@Suite("MCPConnectionError Tests")
struct MCPConnectionErrorTests {

    @Test("Error descriptions")
    func testErrorDescriptions() {
        let notConnected = MCPConnectionError.notConnected
        #expect(notConnected.errorDescription == "Not connected to MCP server")

        let stdioError = MCPConnectionError.stdioNotSupportedOnIOS
        #expect(stdioError.errorDescription == "Stdio transport is not supported on iOS")

        let notFound = MCPConnectionError.serverNotFound("test-server")
        #expect(notFound.errorDescription == "MCP server not found: test-server")
    }
}

@Suite("MCPResourceContent Tests")
struct MCPResourceContentTests {

    @Test("Text resource content")
    func testTextContent() {
        let content = MCPResourceContent(
            uri: "ui://app/view",
            mimeType: "text/html",
            text: "<html><body>Hello</body></html>"
        )

        #expect(content.uri == "ui://app/view")
        #expect(content.mimeType == "text/html")
        #expect(content.text == "<html><body>Hello</body></html>")
        #expect(content.blob == nil)
    }

    @Test("Binary resource content")
    func testBinaryContent() {
        let content = MCPResourceContent(
            uri: "image://app/logo",
            mimeType: "image/png",
            blob: "iVBORw0KGgo="
        )

        #expect(content.uri == "image://app/logo")
        #expect(content.blob == "iVBORw0KGgo=")
        #expect(content.text == nil)
    }
}
