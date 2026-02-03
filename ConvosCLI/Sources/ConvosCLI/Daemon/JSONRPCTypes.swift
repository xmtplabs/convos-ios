import Foundation

// MARK: - JSON-RPC 2.0 Types

/// JSON-RPC request ID can be string, number, or null
enum JSONRPCId: Codable, Sendable, Equatable {
    case string(String)
    case number(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCId.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string, number, or null")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .number(let n):
            try container.encode(n)
        case .null:
            try container.encodeNil()
        }
    }
}

/// JSON-RPC 2.0 request
struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: [String: JSONValue]?
    let id: JSONRPCId?

    func validate() -> JSONRPCError? {
        if jsonrpc != "2.0" {
            return .invalidRequest("jsonrpc must be \"2.0\"")
        }
        if method.isEmpty {
            return .invalidRequest("method is required")
        }
        return nil
    }
}

/// JSON-RPC 2.0 response
struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let result: JSONValue?
    let error: JSONRPCErrorObject?
    let id: JSONRPCId?

    init(result: JSONValue, id: JSONRPCId?) {
        self.jsonrpc = "2.0"
        self.result = result
        self.error = nil
        self.id = id
    }

    init(error: JSONRPCErrorObject, id: JSONRPCId?) {
        self.jsonrpc = "2.0"
        self.result = nil
        self.error = error
        self.id = id
    }
}

/// JSON-RPC error object
struct JSONRPCErrorObject: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Standard JSON-RPC errors
enum JSONRPCError: Error {
    case parseError
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case serverError(code: Int, message: String)

    var object: JSONRPCErrorObject {
        switch self {
        case .parseError:
            return JSONRPCErrorObject(code: -32700, message: "Parse error")
        case .invalidRequest(let msg):
            return JSONRPCErrorObject(code: -32600, message: "Invalid Request: \(msg)")
        case .methodNotFound(let method):
            return JSONRPCErrorObject(code: -32601, message: "Method not found: \(method)")
        case .invalidParams(let msg):
            return JSONRPCErrorObject(code: -32602, message: "Invalid params: \(msg)")
        case .internalError(let msg):
            return JSONRPCErrorObject(code: -32603, message: "Internal error: \(msg)")
        case let .serverError(code, msg):
            return JSONRPCErrorObject(code: code, message: msg)
        }
    }
}

// MARK: - Generic JSON Value

/// Type-erased JSON value for dynamic params/results
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unable to decode JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }

    // Convenience accessors
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - Encodable to JSONValue

extension JSONValue {
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
