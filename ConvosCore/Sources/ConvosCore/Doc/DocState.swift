import Foundation

/// The version-one state snapshot emitted by the first-party Doc agent.
///
/// The message travels as ordinary text so it works over the same XMTP path
/// as the rest of the agent DM. `parse(_:)` is deliberately tolerant of
/// additional envelope and document fields so the runtime can extend the
/// payload without requiring a coordinated client release.
public struct DocState: Codable, Hashable, Sendable {
    public let version: Int
    public let docs: [DocStatus]

    public init(version: Int = 1, docs: [DocStatus]) {
        self.version = version
        self.docs = docs
    }
}

public struct DocStatus: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: String
    public let updatedAt: Date
    public let lastChange: DocLastChange
    public let binding: DocBinding
    public let dates: String?
    public let people: Int?

    public init(
        id: String,
        name: String,
        url: String,
        updatedAt: Date,
        lastChange: DocLastChange,
        binding: DocBinding,
        dates: String? = nil,
        people: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.updatedAt = updatedAt
        self.lastChange = lastChange
        self.binding = binding
        self.dates = dates
        self.people = people
    }

    public var googleURL: URL? {
        guard let url = URL(string: url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" else {
            return nil
        }
        return url
    }
}

public struct DocLastChange: Codable, Hashable, Sendable {
    public let who: String
    public let what: String
    public let at: Date

    public init(who: String, what: String, at: Date) {
        self.who = who
        self.what = what
        self.at = at
    }
}

public struct DocBinding: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case live
        case none
    }

    public let state: State
    public let number: String
    public let group: String?

    public init(state: State, number: String, group: String? = nil) {
        self.state = state
        self.number = number
        self.group = group
    }
}

public enum DocStateMessage {
    public static let prefix: String = "⟦doc⟧"

    public static func isDataPlaneText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    public static func parse(_ text: String) -> DocState? {
        guard isDataPlaneText(text) else { return nil }
        let payload = text.dropFirst(prefix.count)
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
              envelope.version == 1,
              envelope.type == "state" else {
            return nil
        }

        let docs = envelope.docs.compactMap(\.status)
        return DocState(version: envelope.version, docs: docs)
    }

    private struct RawEnvelope: Decodable {
        let version: Int
        let type: String
        let docs: [RawDoc]

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case type = "t"
            case docs
        }
    }

    /// Fields are optional at this boundary so one malformed document does
    /// not discard the rest of an otherwise useful snapshot.
    private struct RawDoc: Decodable {
        let id: String?
        let name: String?
        let url: String?
        let updatedAt: TimeInterval?
        let lastChange: RawLastChange?
        let binding: RawBinding?
        let dates: String?
        let people: Int?

        var status: DocStatus? {
            guard let id, !id.isEmpty,
                  let name, !name.isEmpty,
                  let url,
                  let updatedAt,
                  let lastChange = lastChange?.value,
                  let binding = binding?.value else {
                return nil
            }
            return DocStatus(
                id: id,
                name: name,
                url: url,
                updatedAt: Date(timeIntervalSince1970: updatedAt),
                lastChange: lastChange,
                binding: binding,
                dates: dates,
                people: people
            )
        }
    }

    private struct RawLastChange: Decodable {
        let who: String?
        let what: String?
        let at: TimeInterval?

        var value: DocLastChange? {
            guard let who, !who.isEmpty,
                  let what, !what.isEmpty,
                  let at else {
                return nil
            }
            return DocLastChange(who: who, what: what, at: Date(timeIntervalSince1970: at))
        }
    }

    private struct RawBinding: Decodable {
        let state: String?
        let number: String?
        let group: String?

        var value: DocBinding? {
            guard let state,
                  let state = DocBinding.State(rawValue: state),
                  let number else {
                return nil
            }
            return DocBinding(state: state, number: number, group: group)
        }
    }
}
