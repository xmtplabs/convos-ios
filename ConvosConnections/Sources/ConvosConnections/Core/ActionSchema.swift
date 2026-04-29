import Foundation

/// A uniformly-typed value carried by `ConnectionAction.arguments` and by the `success`
/// branch of `ConnectionInvocationResult`.
///
/// Minimal-but-sufficient for the v1 action set while remaining round-trippable through
/// JSON. Wire form is a tagged object: `{"type": "string", "value": "..."}`.
public enum ArgumentValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case date(Date)
    case iso8601DateTime(String)
    case enumValue(String)
    case array([ArgumentValue])
    case null
}

extension ArgumentValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Tag: String, Codable {
        case string
        case bool
        case int
        case double
        case date
        case iso8601 = "iso8601"
        case enumValue = "enum"
        case array
        case null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Tag.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(Tag.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(Tag.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(Tag.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode(Tag.date, forKey: .type)
            try container.encode(value, forKey: .value)
        case .iso8601DateTime(let value):
            try container.encode(Tag.iso8601, forKey: .type)
            try container.encode(value, forKey: .value)
        case .enumValue(let value):
            try container.encode(Tag.enumValue, forKey: .type)
            try container.encode(value, forKey: .value)
        case .array(let values):
            try container.encode(Tag.array, forKey: .type)
            try container.encode(values, forKey: .value)
        case .null:
            try container.encode(Tag.null, forKey: .type)
            try container.encodeNil(forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Tag.self, forKey: .type)
        switch tag {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .value))
        case .iso8601:
            self = .iso8601DateTime(try container.decode(String.self, forKey: .value))
        case .enumValue:
            self = .enumValue(try container.decode(String.self, forKey: .value))
        case .array:
            self = .array(try container.decode([ArgumentValue].self, forKey: .value))
        case .null:
            self = .null
        }
    }
}

public extension ArgumentValue {
    /// Convenience accessor. Returns `nil` if the value isn't `.string`.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var iso8601Value: String? {
        if case .iso8601DateTime(let value) = self { return value }
        return nil
    }

    var enumRawValue: String? {
        if case .enumValue(let value) = self { return value }
        return nil
    }
}

/// One named parameter of an action schema.
public struct ActionParameter: Sendable, Equatable, Codable {
    public indirect enum ParameterType: Sendable, Equatable {
        case string
        case bool
        case int
        case double
        case date
        case iso8601DateTime
        case enumValue(allowed: [String])
        case arrayOf(ParameterType)
    }

    public let name: String
    public let type: ParameterType
    public let description: String
    public let isRequired: Bool

    public init(name: String, type: ParameterType, description: String, isRequired: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
}

extension ActionParameter.ParameterType: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case allowed
        case element
    }

    private enum Kind: String, Codable {
        case string
        case bool
        case int
        case double
        case date
        case iso8601DateTime = "iso8601"
        case enumValue = "enum"
        case arrayOf = "array"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string:
            try container.encode(Kind.string, forKey: .kind)
        case .bool:
            try container.encode(Kind.bool, forKey: .kind)
        case .int:
            try container.encode(Kind.int, forKey: .kind)
        case .double:
            try container.encode(Kind.double, forKey: .kind)
        case .date:
            try container.encode(Kind.date, forKey: .kind)
        case .iso8601DateTime:
            try container.encode(Kind.iso8601DateTime, forKey: .kind)
        case .enumValue(let allowed):
            try container.encode(Kind.enumValue, forKey: .kind)
            try container.encode(allowed, forKey: .allowed)
        case .arrayOf(let element):
            try container.encode(Kind.arrayOf, forKey: .kind)
            try container.encode(element, forKey: .element)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .string: self = .string
        case .bool: self = .bool
        case .int: self = .int
        case .double: self = .double
        case .date: self = .date
        case .iso8601DateTime: self = .iso8601DateTime
        case .enumValue:
            let allowed = try container.decode([String].self, forKey: .allowed)
            self = .enumValue(allowed: allowed)
        case .arrayOf:
            let element = try container.decode(ActionParameter.ParameterType.self, forKey: .element)
            self = .arrayOf(element)
        }
    }
}

/// Machine-readable schema for one action a `DataSink` can execute.
///
/// Agents fetch these via `DataSink.actionSchemas()` (in-process) or via
/// `ConnectionsManager.actionSchemas(for:)` and use them to construct a valid
/// `ConnectionInvocation`.
public struct ActionSchema: Sendable, Equatable, Codable, Identifiable {
    public var id: String { "\(kind.rawValue).\(actionName)" }

    public let kind: ConnectionKind
    public let actionName: String
    public let capability: ConnectionCapability
    public let summary: String
    public let inputs: [ActionParameter]
    public let outputs: [ActionParameter]

    public init(
        kind: ConnectionKind,
        actionName: String,
        capability: ConnectionCapability,
        summary: String,
        inputs: [ActionParameter],
        outputs: [ActionParameter]
    ) {
        self.kind = kind
        self.actionName = actionName
        self.capability = capability
        self.summary = summary
        self.inputs = inputs
        self.outputs = outputs
    }
}

/// The agent-side view of an action invocation: which action, what arguments.
public struct ConnectionAction: Sendable, Equatable, Codable {
    public let name: String
    public let arguments: [String: ArgumentValue]

    public init(name: String, arguments: [String: ArgumentValue]) {
        self.name = name
        self.arguments = arguments
    }
}
