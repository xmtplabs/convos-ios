import Foundation

public enum MCPAppProtocol {
    public static let protocolVersion: String = "2026-01-26"

    public enum Method: String, Sendable {
        case initialize = "ui/initialize"
        case initialized = "ui/notifications/initialized"
        case toolInput = "ui/notifications/tool-input"
        case toolInputPartial = "ui/notifications/tool-input-partial"
        case toolResult = "ui/notifications/tool-result"
        case toolCancelled = "ui/notifications/tool-cancelled"
        case hostContextChanged = "ui/notifications/host-context-changed"
        case sizeChanged = "ui/notifications/size-changed"
        case message = "ui/message"
        case openLink = "ui/open-link"
        case updateModelContext = "ui/update-model-context"
        case requestDisplayMode = "ui/request-display-mode"
        case resourceTeardown = "ui/resource-teardown"
        case downloadFile = "ui/download-file"
        case toolsCall = "tools/call"
        case resourcesRead = "resources/read"
        case ping = "ping"
    }
}

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let method: String
    public let params: JSONValue?

    public init(id: Int? = nil, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: Int, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: Int, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let methodNotFound: JSONRPCError = .init(code: -32601, message: "Method not found")
    public static let invalidParams: JSONRPCError = .init(code: -32602, message: "Invalid params")
    public static func serverError(_ message: String) -> JSONRPCError {
        .init(code: -32000, message: message)
    }
}

public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }
}

public struct MCPAppInitializeParams: Codable, Sendable {
    public let appInfo: AppInfo
    public let appCapabilities: JSONValue?
    public let protocolVersion: String

    public struct AppInfo: Codable, Sendable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }
}

public struct MCPAppHostContext: Codable, Sendable {
    public var theme: String?
    public var styles: Styles?
    public var displayMode: String?
    public var availableDisplayModes: [String]?
    public var containerDimensions: JSONValue?
    public var toolInfo: ToolInfo?
    public var locale: String?
    public var timeZone: String?
    public var platform: String?

    public struct Styles: Codable, Sendable {
        public var variables: [String: String]?
        public var css: CSSInfo?

        public init(variables: [String: String]? = nil, css: CSSInfo? = nil) {
            self.variables = variables
            self.css = css
        }

        public struct CSSInfo: Codable, Sendable {
            public var fonts: String?

            public init(fonts: String? = nil) {
                self.fonts = fonts
            }
        }
    }

    public struct ToolInfo: Codable, Sendable {
        public var id: JSONValue?
        public var tool: JSONValue?

        public init(id: JSONValue? = nil, tool: JSONValue? = nil) {
            self.id = id
            self.tool = tool
        }
    }

    public init(
        theme: String? = nil,
        styles: Styles? = nil,
        displayMode: String? = nil,
        availableDisplayModes: [String]? = nil,
        containerDimensions: JSONValue? = nil,
        toolInfo: ToolInfo? = nil,
        locale: String? = nil,
        timeZone: String? = nil,
        platform: String? = nil
    ) {
        self.theme = theme
        self.styles = styles
        self.displayMode = displayMode
        self.availableDisplayModes = availableDisplayModes
        self.containerDimensions = containerDimensions
        self.toolInfo = toolInfo
        self.locale = locale
        self.timeZone = timeZone
        self.platform = platform
    }
}

public struct MCPAppInitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let hostInfo: HostInfo
    public let hostCapabilities: JSONValue
    public let hostContext: MCPAppHostContext

    public struct HostInfo: Codable, Sendable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public init(
        protocolVersion: String = MCPAppProtocol.protocolVersion,
        hostInfo: HostInfo,
        hostCapabilities: JSONValue = .object([:]),
        hostContext: MCPAppHostContext
    ) {
        self.protocolVersion = protocolVersion
        self.hostInfo = hostInfo
        self.hostCapabilities = hostCapabilities
        self.hostContext = hostContext
    }
}
