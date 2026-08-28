import ConvosCore
import Foundation

enum DocGroupRelationship: Hashable {
    case loading
    case standalone
    case connecting(lineNumber: String)
    case connected(identity: DocGroupIdentity, boundAt: Date?)
    case ended(identity: DocGroupIdentity)

    static func project(
        doc: DocStatus,
        controlBinding: DocControlBinding?,
        isControlLoaded: Bool,
        content: DocContent?
    ) -> DocGroupRelationship {
        guard isControlLoaded else { return .loading }
        guard let controlBinding else { return .standalone }

        switch controlBinding.status {
        case .pending:
            guard controlBinding.conversationType != .dm else { return .standalone }
            return .connecting(lineNumber: controlBinding.lineNumber)
        case .live:
            guard controlBinding.conversationType == .group else { return .standalone }
            return .connected(
                identity: DocGroupIdentity(
                    groupName: controlBinding.groupName,
                    observedMembers: DocGroupIdentity.observedMembers(doc: doc, content: content),
                    hasUnidentifiedUpdates: DocGroupIdentity.hasUnidentifiedUpdates(content: content)
                ),
                boundAt: controlBinding.boundAt.flatMap(Self.date)
            )
        case .released:
            guard controlBinding.conversationType == .group else { return .standalone }
            return .ended(identity: DocGroupIdentity(
                groupName: controlBinding.groupName,
                observedMembers: DocGroupIdentity.observedMembers(doc: doc, content: content),
                hasUnidentifiedUpdates: DocGroupIdentity.hasUnidentifiedUpdates(content: content)
            ))
        }
    }

    var lineNumber: String? {
        guard case .connecting(let lineNumber) = self else { return nil }
        return lineNumber
    }

    var connectedIdentity: DocGroupIdentity? {
        guard case .connected(let identity, _) = self else { return nil }
        return identity
    }

    private static func date(from epochSeconds: Int64) -> Date? {
        guard epochSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }
}

struct DocGroupIdentity: Hashable {
    let groupName: String?
    let observedMembers: [String]
    let hasUnidentifiedUpdates: Bool

    init(
        groupName: String?,
        observedMembers: [String],
        hasUnidentifiedUpdates: Bool = false
    ) {
        self.groupName = groupName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.observedMembers = observedMembers
        self.hasUnidentifiedUpdates = hasUnidentifiedUpdates
    }

    var homeHeadline: String {
        if let groupName { return "Connected to \(groupName)" }
        if !observedMembers.isEmpty { return "Connected to your group with \(memberList)" }
        return "Connected to an iMessage group"
    }

    var roomTitle: String {
        if let groupName { return groupName }
        if !observedMembers.isEmpty { return "Your group with \(memberList)" }
        return "An iMessage group"
    }

    var namedGroupMemberContext: String? {
        guard groupName != nil, !observedMembers.isEmpty else { return nil }
        return "With \(memberList)"
    }

    var memberList: String {
        observedMembers.joined(separator: ", ")
    }

    static func observedMembers(doc: DocStatus, content: DocContent?) -> [String] {
        var senders: [String] = content?.changes.map(\.who) ?? []
        senders.append(doc.lastChange.who)
        var normalizedSenders: Set<String> = []
        var members: [String] = []

        for sender in senders {
            let cleaned = sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !isPlaceholder(cleaned) else { continue }
            let displayName = displayIdentity(cleaned)
            let comparisonKey = displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard normalizedSenders.insert(comparisonKey).inserted else { continue }
            members.append(displayName)
            if members.count == Constant.maximumVisibleMembers { break }
        }
        return members
    }

    static func hasUnidentifiedUpdates(content: DocContent?) -> Bool {
        content?.changes.contains(where: { isPlaceholder($0.who) }) == true
    }

    private static func displayIdentity(_ sender: String) -> String {
        let digits = sender.filter(\.isNumber)
        let nonPhoneCharacters = sender.unicodeScalars.filter {
            !CharacterSet(charactersIn: "+()-. ").contains($0) && !CharacterSet.decimalDigits.contains($0)
        }
        guard nonPhoneCharacters.isEmpty, digits.count >= 10 else { return sender }
        return docDisplayPhoneNumber(sender)
    }

    private static func isPlaceholder(_ sender: String) -> Bool {
        let normalized = sender
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Constant.placeholderSenders.contains(normalized) || normalized.hasPrefix("unknown ")
    }

    private enum Constant {
        static let maximumVisibleMembers: Int = 3
        static let placeholderSenders: Set<String> = [
            "@doc",
            "a group member",
            "doc",
            "group member",
            "someone",
            "unknown",
            "unknown contributor",
            "you",
        ]
    }
}

struct DocUnmatchedGroupProgress: Equatable, Identifiable {
    let id: String
    let groupName: String?

    var body: String {
        if let groupName, !groupName.isEmpty { return "Making a doc for \(groupName)…" }
        return "Making a doc for a new iMessage group…"
    }
}

enum DocGroupShareCopy {
    static func text(docName: String, lineNumber: String) -> String {
        let number = docDisplayPhoneNumber(lineNumber)
        return "Add @doc to this iMessage group, then send any message there so I can connect it to “\(docName)”: \(number)"
    }
}

struct DocGroupConflictCopy: Equatable {
    let headline: String
    let context: String = "A group can update one doc."
    let openAction: String
    let keepAction: String = "Keep this standalone"

    init(groupName: String, connectedDocName: String) {
        headline = "\(groupName) is already connected to \(connectedDocName)."
        openAction = "Open \(connectedDocName)"
    }
}

enum DocGroupConfirmationPresentation {
    static let confirmLabel: String = "Yes, connect"
    static let rejectLabel: String = "Not this group"
    static let legacyConfirmValue: String = "Yes, bind it"
    static let legacyRejectValue: String = "No"

    static func matches(_ item: DocWaitingItem) -> Bool {
        item.register == .waiting &&
            item.kind == .question &&
            item.docId != nil &&
            item.chips == [legacyConfirmValue, legacyRejectValue]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
