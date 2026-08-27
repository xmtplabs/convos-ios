import Foundation

public struct ConversationUpdate: Hashable, Codable, Sendable {
    public struct MetadataChange: Hashable, Codable, Sendable {
        public enum Field: String, Codable, Sendable {
            case name = "group_name",
                 description = "description",
                 image = "group_image_url_square",
                 expiresAt = "expiresAt",
                 metadata = "app_data",
                 // Synthesized while decoding an `app_data` change: that blob
                 // carries every custom field, and only a mode change in it
                 // earns a transcript row.
                 participationMode = "participation_mode",
                 // Also synthesized while decoding an `app_data` change: the
                 // model lives on an agent's profile inside that same blob.
                 // Carries the model id, not a member-facing name — the
                 // catalogue that names it lives in the agent's container, and
                 // the transcript must render from the commit alone.
                 agentModel = "agent_model",
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

    /// `true` when this update added at least one member that is a verified
    /// Convos agent. Used to gate verified-agent UI affordances, such as
    /// anchoring the agent contact card beneath the join row, which should
    /// only appear for verified agents, never for regular members or
    /// unverified agents.
    public var addedVerifiedAgent: Bool {
        addedMembers.contains { $0.isAgent && $0.agentVerification.isConvosAgent }
    }

    var showsInMessagesList: Bool {
        guard metadataChanges.allSatisfy({ $0.field.showsInMessagesList }) else {
            return false
        }
        return !summary.isEmpty
    }
}
