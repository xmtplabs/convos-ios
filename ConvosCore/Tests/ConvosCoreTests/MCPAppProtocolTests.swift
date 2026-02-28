@testable import ConvosCore
import Foundation
import Testing

@Suite("MCPAppProtocol")
struct MCPAppProtocolTests {
    @Test("Protocol version matches spec")
    func protocolVersion() {
        #expect(MCPAppProtocol.protocolVersion == "2026-01-26")
    }

    @Test("All ui/ methods have correct raw values")
    func methodRawValues() {
        #expect(MCPAppProtocol.Method.initialize.rawValue == "ui/initialize")
        #expect(MCPAppProtocol.Method.initialized.rawValue == "ui/notifications/initialized")
        #expect(MCPAppProtocol.Method.toolInput.rawValue == "ui/notifications/tool-input")
        #expect(MCPAppProtocol.Method.toolInputPartial.rawValue == "ui/notifications/tool-input-partial")
        #expect(MCPAppProtocol.Method.toolResult.rawValue == "ui/notifications/tool-result")
        #expect(MCPAppProtocol.Method.toolCancelled.rawValue == "ui/notifications/tool-cancelled")
        #expect(MCPAppProtocol.Method.hostContextChanged.rawValue == "ui/notifications/host-context-changed")
        #expect(MCPAppProtocol.Method.sizeChanged.rawValue == "ui/notifications/size-changed")
        #expect(MCPAppProtocol.Method.message.rawValue == "ui/message")
        #expect(MCPAppProtocol.Method.openLink.rawValue == "ui/open-link")
        #expect(MCPAppProtocol.Method.updateModelContext.rawValue == "ui/update-model-context")
        #expect(MCPAppProtocol.Method.requestDisplayMode.rawValue == "ui/request-display-mode")
        #expect(MCPAppProtocol.Method.resourceTeardown.rawValue == "ui/resource-teardown")
        #expect(MCPAppProtocol.Method.downloadFile.rawValue == "ui/download-file")
        #expect(MCPAppProtocol.Method.toolsCall.rawValue == "tools/call")
        #expect(MCPAppProtocol.Method.resourcesRead.rawValue == "resources/read")
        #expect(MCPAppProtocol.Method.ping.rawValue == "ping")
    }
}

@Suite("JSONRPCRequest")
struct JSONRPCRequestTests {
    @Test("Request encodes with id")
    func requestWithId() throws {
        let request = JSONRPCRequest(id: 1, method: "ui/initialize", params: .object(["key": .string("value")]))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        #expect(decoded.jsonrpc == "2.0")
        #expect(decoded.id == 1)
        #expect(decoded.method == "ui/initialize")
        #expect(decoded.isNotification == false)
    }

    @Test("Notification encodes without id")
    func notification() throws {
        let notification = JSONRPCRequest(method: "ui/notifications/initialized")
        let data = try JSONEncoder().encode(notification)
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        #expect(decoded.id == nil)
        #expect(decoded.isNotification == true)
    }
}

@Suite("JSONRPCResponse")
struct JSONRPCResponseTests {
    @Test("Success response encodes correctly")
    func successResponse() throws {
        let response = JSONRPCResponse(id: 1, result: .object(["status": .string("ok")]))
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(decoded.jsonrpc == "2.0")
        #expect(decoded.id == 1)
        #expect(decoded.error == nil)
        #expect(decoded.result?["status"]?.stringValue == "ok")
    }

    @Test("Error response encodes correctly")
    func errorResponse() throws {
        let response = JSONRPCResponse(id: 2, error: .methodNotFound)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(decoded.id == 2)
        #expect(decoded.error?.code == -32601)
        #expect(decoded.error?.message == "Method not found")
        #expect(decoded.result == nil)
    }

    @Test("Server error factory")
    func serverError() {
        let error = JSONRPCError.serverError("Something failed")
        #expect(error.code == -32000)
        #expect(error.message == "Something failed")
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Null round-trip")
    func nullRoundTrip() throws {
        let value: JSONValue = .null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .null)
    }

    @Test("Bool round-trip")
    func boolRoundTrip() throws {
        let value: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .bool(true))
    }

    @Test("Int round-trip")
    func intRoundTrip() throws {
        let value: JSONValue = .int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .int(42))
    }

    @Test("Double round-trip")
    func doubleRoundTrip() throws {
        let value: JSONValue = .double(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .double(3.14))
    }

    @Test("String round-trip")
    func stringRoundTrip() throws {
        let value: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .string("hello"))
    }

    @Test("Array round-trip")
    func arrayRoundTrip() throws {
        let value: JSONValue = .array([.int(1), .string("two"), .bool(true)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Object round-trip")
    func objectRoundTrip() throws {
        let value: JSONValue = .object(["name": .string("test"), "count": .int(5)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Nested structure round-trip")
    func nestedRoundTrip() throws {
        let value: JSONValue = .object([
            "items": .array([
                .object(["id": .int(1), "name": .string("first")]),
                .object(["id": .int(2), "name": .string("second")])
            ]),
            "total": .int(2),
            "meta": .null
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Accessor helpers")
    func accessors() {
        let value: JSONValue = .object(["name": .string("test"), "items": .array([.int(1)])])
        #expect(value["name"]?.stringValue == "test")
        #expect(value["items"]?.arrayValue?.count == 1)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("hello").stringValue == "hello")
        #expect(JSONValue.int(42).stringValue == nil)
        #expect(JSONValue.object([:]).objectValue != nil)
    }
}

@Suite("MCPAppInitializeResult")
struct MCPAppInitializeResultTests {
    @Test("Initialize result round-trip")
    func roundTrip() throws {
        let context = MCPAppHostContext(
            theme: "dark",
            styles: .init(variables: ["--mcp-color-primary": "#FFFFFF"]),
            displayMode: "inline",
            availableDisplayModes: ["inline"],
            platform: "mobile"
        )
        let result = MCPAppInitializeResult(
            hostInfo: .init(name: "Convos", version: "1.0.0"),
            hostContext: context
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MCPAppInitializeResult.self, from: data)
        #expect(decoded.protocolVersion == "2026-01-26")
        #expect(decoded.hostInfo.name == "Convos")
        #expect(decoded.hostInfo.version == "1.0.0")
        #expect(decoded.hostContext.theme == "dark")
        #expect(decoded.hostContext.platform == "mobile")
        #expect(decoded.hostContext.styles?.variables?["--mcp-color-primary"] == "#FFFFFF")
    }

    @Test("Host context with all fields")
    func hostContextAllFields() throws {
        let context = MCPAppHostContext(
            theme: "light",
            styles: .init(
                variables: ["--color-bg": "#FFF"],
                css: .init(fonts: "@font-face { }")
            ),
            displayMode: "inline",
            availableDisplayModes: ["inline", "fullscreen"],
            containerDimensions: .object(["width": .int(300), "maxHeight": .int(600)]),
            toolInfo: .init(id: .int(1), tool: .object(["name": .string("weather")])),
            locale: "en-US",
            timeZone: "America/Los_Angeles",
            platform: "mobile"
        )
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(MCPAppHostContext.self, from: data)
        #expect(decoded.locale == "en-US")
        #expect(decoded.timeZone == "America/Los_Angeles")
        #expect(decoded.styles?.css?.fonts == "@font-face { }")
    }
}

@Suite("MCPAppInitializeParams")
struct MCPAppInitializeParamsTests {
    @Test("Decode initialize params from JSON")
    func decodeFromJSON() throws {
        let json = """
        {
            "appInfo": {"name": "Weather", "version": "1.0.0"},
            "appCapabilities": {},
            "protocolVersion": "2026-01-26"
        }
        """
        let data = Data(json.utf8)
        let params = try JSONDecoder().decode(MCPAppInitializeParams.self, from: data)
        #expect(params.appInfo.name == "Weather")
        #expect(params.appInfo.version == "1.0.0")
        #expect(params.protocolVersion == "2026-01-26")
    }
}
