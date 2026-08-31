import Foundation

/// One JSON value from a Space document.
///
/// A document's props are whatever the page author wrote, so they cannot be
/// modelled as a fixed shape. Decoding them into this enum keeps the whole
/// tree readable without the client having to know every component's schema —
/// which is the point of the document contract: the app renders the parts it
/// recognises and carries the rest untouched.
indirect enum SpaceValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SpaceValue])
    case object([String: SpaceValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool is checked before Number: JSONDecoder will happily read `true`
        // as 1, and a flag that arrives as a number stops matching `.bool`.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SpaceValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SpaceValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in Space document"
            )
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case let .number(value) = self { return Int(value) }
        return nil
    }

    var arrayValue: [SpaceValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: SpaceValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

/// One evaluated component in a Space document's tree.
///
/// The server settles every query and evaluates every prop before serving, so
/// a node carries concrete values only — there is nothing left to resolve here.
struct SpaceNode: Equatable {
    let typeName: String
    let statementId: String?
    let props: [String: SpaceValue]

    /// Reads a node out of a decoded value, or `nil` when the value is
    /// ordinary data rather than a component.
    init?(_ value: SpaceValue) {
        guard let fields = value.objectValue,
              fields["type"]?.stringValue == "element",
              let typeName = fields["typeName"]?.stringValue else {
            return nil
        }
        self.typeName = typeName
        statementId = fields["statementId"]?.stringValue
        props = fields["props"]?.objectValue ?? [:]
    }

    /// The child components this node draws, in reading order.
    var children: [SpaceNode] {
        props["children"]?.arrayValue?.compactMap(SpaceNode.init) ?? []
    }

    /// Every node in this subtree, including this one.
    func flattened() -> [SpaceNode] {
        [self] + children.flatMap { $0.flattened() }
    }

    // Prop readers. A document's props are author-written, so every one of
    // these answers "absent" rather than trapping: a tile that is missing a
    // field draws without it instead of taking the page down.

    func string(_ name: String) -> String? {
        props[name]?.stringValue
    }

    func int(_ name: String) -> Int? {
        props[name]?.intValue
    }

    func strings(_ name: String) -> [String] {
        props[name]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// The component children of one prop, skipping anything that is plain data.
    func nodes(_ name: String) -> [SpaceNode] {
        props[name]?.arrayValue?.compactMap(SpaceNode.init) ?? []
    }

    /// The object rows of one prop, for props that carry data rather than
    /// components — a reminder's `{label, done}`, a member's `{name, imageUrl}`.
    func rows(_ name: String) -> [[String: SpaceValue]] {
        props[name]?.arrayValue?.compactMap(\.objectValue) ?? []
    }
}

extension [String: SpaceValue] {
    func string(_ name: String) -> String? {
        self[name]?.stringValue
    }

    func bool(_ name: String) -> Bool? {
        if case let .bool(value)? = self[name] { return value }
        return nil
    }
}

/// One home-screen tile, as the app needs it to draw a cell.
///
/// The tile's frame comes from these fields; what it draws inside comes from
/// `preview`, whose own component name is the tile's type.
struct SpaceWidget: Identifiable, Equatable {
    let title: String
    let route: String
    let size: String
    let itemCount: Int?
    /// The route a single-item tile opens instead of its collection.
    let itemHref: String?
    /// What the tile draws: the first component in its children, whose own name
    /// is the tile's type (`NotesPreview`, `EventsPreview`, …).
    let preview: SpaceNode?

    var id: String { route }

    /// How many grid columns this tile spans.
    var columnSpan: Int { size == "1x1" ? 1 : 2 }

    /// The tile's width-to-height ratio, matching the web grid.
    ///
    /// With a tile edge `t` and gutter `g`, a full-width tile is `2t + g`
    /// across. `2x1` keeps a single tile's height, so it is that much wider
    /// than tall; `2x2` is two tiles plus the gutter in both directions, which
    /// makes it square again.
    var aspectRatio: CGFloat {
        switch size {
        case "2x1": (2 * 165.0 + 24.0) / 165.0
        default: 1.0
        }
    }

    /// Where a tap should go: a collection holding exactly one item opens that
    /// item directly, which is the rule the web tile follows.
    var destination: String {
        guard let itemHref, itemCount == 1 else { return route }
        return itemHref
    }

    init?(_ node: SpaceNode) {
        guard node.typeName == "Widget",
              let title = node.props["title"]?.stringValue,
              let route = node.props["route"]?.stringValue else {
            return nil
        }
        self.title = title
        self.route = route
        size = node.props["size"]?.stringValue ?? "1x1"
        itemCount = node.props["itemCount"]?.intValue
        itemHref = node.props["itemHref"]?.stringValue
        preview = node.children.first
    }
}

/// One routed Space page, served as its evaluated component tree.
struct SpaceDocument: Decodable, Equatable {
    struct Metadata: Decodable, Equatable {
        let title: String?
        let description: String?
    }

    let deploymentId: String
    let commitSha: String
    let route: String
    /// The base a committed asset path resolves against, absent on a deployment
    /// that predates the field.
    let fileBasePath: String?
    let metadata: Metadata
    private let root: SpaceValue

    /// The document's root component, when the tree decodes to one.
    var rootNode: SpaceNode? { SpaceNode(root) }

    /// Every tile the page lays out, in document order.
    var widgets: [SpaceWidget] {
        rootNode?.flattened().compactMap(SpaceWidget.init) ?? []
    }
}

extension SpaceDocument {
    /// The home page every Space opens with, drawn before that Space exists.
    ///
    /// A conversation's Space is forked, built and activated before its URL is
    /// published, so the tab has nothing of its own to draw for as long as that
    /// takes. It does not need to wait: the starter's home page is the same for
    /// every Space, and the one part of it that differs — who is in the group —
    /// is something the app already knows. So the tab draws the real page and
    /// swaps to the served document when it arrives.
    ///
    /// Only what is actually known goes in. The notes tile draws its header and
    /// no rows, because a brand-new Space's notes are the Space's to report, not
    /// this file's to guess.
    ///
    /// Built as JSON and decoded, so it takes exactly the path a served document
    /// takes. A second way of constructing a document would drift from the one
    /// that matters.
    static func firstRun(memberNames: [String]) -> SpaceDocument? {
        let members = memberNames.map { name in
            ["name": name] as [String: Any]
        }
        let page: [String: Any] = [
            // No deployment has served this, and that is the point: any real
            // document differs, so the first one to arrive replaces it.
            "deploymentId": "",
            "commitSha": "",
            "route": "/",
            "metadata": ["title": "Home", "description": "This group's space"],
            "root": element("Page", statementId: "root", props: [
                "children": [
                    element("Intro", props: [
                        "headline": "Welcome home",
                        "body": element("Markdown", props: [
                            "text": Constant.introBody
                        ])
                    ]),
                    element("WidgetGrid", props: [
                        "children": [
                            element("Widget", props: [
                                "title": "Notes",
                                "route": "/notes",
                                "size": "1x1",
                                "children": [
                                    element("NotesPreview", props: [
                                        "count": 0,
                                        "notes": []
                                    ])
                                ]
                            ]),
                            element("Widget", props: [
                                "title": "Directory",
                                "route": "/directory",
                                "size": "1x1",
                                "children": [
                                    element("DirectoryPreview", props: [
                                        "members": members
                                    ])
                                ]
                            ])
                        ]
                    ]),
                    element("AskAgentButton", props: [
                        "label": "Add anything",
                        "note": "Ask your agent to create a page, list, note, or app"
                    ])
                ]
            ])
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: page) else {
            return nil
        }
        return try? JSONDecoder().decode(SpaceDocument.self, from: data)
    }

    /// One component, in the shape the document wire uses.
    private static func element(
        _ typeName: String,
        statementId: String? = nil,
        props: [String: Any]
    ) -> [String: Any] {
        var node: [String: Any] = [
            "type": "element",
            "typeName": typeName,
            "props": props
        ]
        if let statementId {
            node["statementId"] = statementId
        }
        return node
    }

    private enum Constant {
        /// Verbatim from the starter's `pages/index.page`.
        static let introBody: String =
            "This is where your group's stuff lives — the plans, lists, and "
            + "notes that would otherwise scroll away in the chat.\n\n"
            + "It's yours and your agent's to shape together. Tell your agent "
            + "what to add or change, and this is where it lands."
    }
}
