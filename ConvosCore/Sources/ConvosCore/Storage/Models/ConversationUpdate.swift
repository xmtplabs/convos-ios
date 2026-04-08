import Foundation

public struct ConversationUpdate: Hashable, Codable, Sendable {
    public struct MetadataChange: Hashable, Codable, Sendable {
        public enum Field: String, Codable, Sendable {
            case name = "group_name",
                 description = "description",
                 image = "group_image_url_square",
                 expiresAt = "expiresAt",
                 metadata = "app_data",
                 unknown

            var showsInMessagesList: Bool {
                switch self {
                case .unknown, .metadata:
                    false
                default:
                    true
                }
            }
        }
        public let field: Field
        public let oldValue: String?
        public let newValue: String?
    }

    public let creator: ConversationMember
    public let addedMembers: [ConversationMember]
    public let removedMembers: [ConversationMember]
    public let metadataChanges: [MetadataChange]
    public let isReconnection: Bool

    public var profileMember: ConversationMember? {
        if !addedMembers.isEmpty && !removedMembers.isEmpty {
            return creator
        } else if !addedMembers.isEmpty {
            if addedMembers.count == 1, let member = addedMembers.first {
                return member
            } else {
                return nil
            }
        } else if !removedMembers.isEmpty {
            if removedMembers.count == 1, let member = removedMembers.first {
                return member
            } else {
                return nil
            }
        } else if let change = metadataChanges.first,
                  change.field != .image || change.newValue != nil {
            return creator
        } else {
            return nil
        }
    }

    public var profile: Profile? {
        profileMember?.profile
    }

    public var addedAgent: Bool {
        addedMembers.contains(where: \.isAgent)
    }

    var showsInMessagesList: Bool {
        guard metadataChanges.allSatisfy({ $0.field.showsInMessagesList }) else {
            return false
        }
        return !summary.isEmpty
    }
}
