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

public struct DocWaitingItem: Codable, Hashable, Identifiable, Sendable {
    public enum Register: String, Codable, Hashable, Sendable {
        case waiting
    }

    public enum Kind: String, Codable, Hashable, Sendable {
        case question
        case unknownContributor = "unknown_contributor"
        case noticeAsk = "notice_ask"
    }

    public let id: String
    public let register: Register
    public let kind: Kind
    public let headline: String
    public let context: String
    public let chips: [String]
    public let docId: String?
    public let createdAt: Date

    public init(
        id: String,
        register: Register = .waiting,
        kind: Kind,
        headline: String,
        context: String,
        chips: [String] = [],
        docId: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.register = register
        self.kind = kind
        self.headline = headline
        self.context = context
        self.chips = chips
        self.docId = docId
        self.createdAt = createdAt
    }
}

public struct DocContent: Codable, Hashable, Identifiable, Sendable {
    public let docId: String
    public let markdown: String
    public let changes: [DocLastChange]
    public let updatedAt: Date

    public var id: String { docId }

    public init(
        docId: String,
        markdown: String,
        changes: [DocLastChange],
        updatedAt: Date
    ) {
        self.docId = docId
        self.markdown = markdown
        self.changes = changes
        self.updatedAt = updatedAt
    }
}

public enum DocAgentEvent: Hashable, Sendable {
    case state(DocState)
    case item(DocWaitingItem)
    case itemResolved(id: String)
    case docContent(DocContent)
}

public enum DocAnswer: Hashable, Sendable {
    case choice(String)
    case text(String)
}

public enum DocWireMessage {
    public static func isHiddenText(_ text: String) -> Bool {
        DocStateMessage.isDataPlaneText(text) ||
            DocAnswerMessage.isDataPlaneText(text) ||
            DocContentRequestMessage.isDataPlaneText(text)
    }
}

public enum DocStateMessage {
    public static let prefix: String = "⟦doc⟧"

    public static func isDataPlaneText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    public static func parse(_ text: String) -> DocState? {
        guard case .state(let state) = parseEvent(text) else { return nil }
        return state
    }

    public static func parseEvent(_ text: String) -> DocAgentEvent? {
        guard isDataPlaneText(text) else { return nil }
        let payload = text.dropFirst(prefix.count)
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
              envelope.version == 1 else {
            return nil
        }

        switch envelope.type {
        case "state":
            guard let rawDocs = envelope.docs else { return nil }
            let docs: [DocStatus] = rawDocs.compactMap(\.status)
            return .state(DocState(version: envelope.version, docs: docs))
        case "item":
            guard let item = envelope.item?.value else { return nil }
            return .item(item)
        case "item-resolved":
            guard let id = envelope.id, !id.isEmpty else { return nil }
            return .itemResolved(id: id)
        case "doc-content":
            guard let docId = envelope.docId,
                  !docId.isEmpty,
                  let markdown = envelope.markdown,
                  let updatedAt = envelope.updatedAt,
                  updatedAt.isFinite else {
                return nil
            }
            let changes = (envelope.changes ?? [])
                .compactMap(\.value)
                .sorted { $0.at > $1.at }
            return .docContent(
                DocContent(
                    docId: docId,
                    markdown: markdown,
                    changes: changes,
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            )
        default:
            return nil
        }
    }

    private struct RawEnvelope: Decodable {
        let version: Int
        let type: String
        let docs: [RawDoc]?
        let item: RawItem?
        let id: String?
        let docId: String?
        let markdown: String?
        let changes: [RawLastChange]?
        let updatedAt: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case type = "t"
            case docs
            case item
            case id
            case docId
            case markdown
            case changes
            case updatedAt
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

    private struct RawItem: Decodable {
        let id: String?
        let register: String?
        let kind: String?
        let headline: String?
        let context: String?
        let chips: [String]?
        let docId: String?
        let createdAt: TimeInterval?

        var value: DocWaitingItem? {
            guard let id, !id.isEmpty,
                  let register,
                  let register = DocWaitingItem.Register(rawValue: register),
                  let kind,
                  let kind = DocWaitingItem.Kind(rawValue: kind),
                  let headline, !headline.isEmpty,
                  let context, !context.isEmpty,
                  let createdAt, createdAt.isFinite else {
                return nil
            }
            let cleanChips: [String] = (chips ?? []).filter { !$0.isEmpty }
            return DocWaitingItem(
                id: id,
                register: register,
                kind: kind,
                headline: headline,
                context: context,
                chips: cleanChips,
                docId: docId,
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }
    }
}

public enum DocContentRequestMessage {
    public static let prefix: String = "⟦req⟧"

    public static func isDataPlaneText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    public static func encode(docId: String) -> String? {
        guard !docId.isEmpty,
              let data = try? JSONEncoder().encode(RequestEnvelope(type: "doc-content", docId: docId)),
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "\(prefix)\(payload)"
    }

    private struct RequestEnvelope: Encodable {
        let type: String
        let docId: String

        private enum CodingKeys: String, CodingKey {
            case type = "t"
            case docId
        }
    }
}

public enum DocAnswerMessage {
    public static let prefix: String = "⟦ans⟧"

    public static func isDataPlaneText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    public static func encode(itemId: String, answer: DocAnswer) -> String? {
        guard !itemId.isEmpty else { return nil }
        let envelope = AnswerEnvelope(id: itemId, answer: answer)
        guard let data = try? JSONEncoder().encode(envelope),
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "\(prefix)\(payload)"
    }

    private struct AnswerEnvelope: Encodable {
        let id: String
        let answer: DocAnswer

        private enum CodingKeys: String, CodingKey {
            case id
            case choice
            case text
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            switch answer {
            case .choice(let choice):
                try container.encode(choice, forKey: .choice)
            case .text(let text):
                try container.encode(text, forKey: .text)
            }
        }
    }
}
