import Foundation
import GRDB

public protocol AgentTimezonePublishing: Sendable {
    /// Publishes the current device's IANA timezone identifier into the
    /// sender's per-conversation `ProfileUpdate.metadata` under the `timezone`
    /// key, but only when the conversation already contains an agent member.
    /// Best-effort: a failure is logged and swallowed so it never blocks the
    /// caller (e.g. an agent join).
    func publishTimezoneIfAgentConversation(conversationId: String) async

    /// Republishes the timezone for every conversation that contains an agent
    /// member, throttled so a conversation is only republished when the current
    /// timezone differs from the last value published for it. Intended for the
    /// opportunistic app-foreground refresh.
    func republishTimezoneForAgentConversations() async
}

/// Per-sender timezone publish (Channel B in the agent-timezone design).
///
/// The device timezone is captured up front on the main actor (timezone reads
/// touch regional settings synchronously) and then written through the shared
/// `ProfileMetadataWriter`, so a timezone write and a connections write can
/// never race on the per-sender metadata map.
///
/// Scope: agent conversations only. A timezone has no purpose for human peers
/// and must not leak into human-only conversations. Writes only ever happen
/// from the foreground main app -- never the Notification Service Extension or
/// a background task.
public final class AgentTimezonePublisher: AgentTimezonePublishing, @unchecked Sendable {
    private let profileMetadataWriter: any ProfileMetadataWriterProtocol
    private let databaseReader: any DatabaseReader
    private let myInboxId: String
    private let appGroupIdentifier: String

    public init(
        profileMetadataWriter: any ProfileMetadataWriterProtocol,
        databaseReader: any DatabaseReader,
        myInboxId: String,
        appGroupIdentifier: String
    ) {
        self.profileMetadataWriter = profileMetadataWriter
        self.databaseReader = databaseReader
        self.myInboxId = myInboxId
        self.appGroupIdentifier = appGroupIdentifier
    }

    public func publishTimezoneIfAgentConversation(conversationId: String) async {
        let currentTimezone = await currentDeviceTimezone()
        do {
            let hasAgent = try await databaseReader.read { db in
                try OutgoingMessageWriter.hasCurrentAgentMember(db: db, conversationId: conversationId)
            }
            guard hasAgent else { return }
            try await publish(timezone: currentTimezone, conversationId: conversationId)
        } catch {
            Log.warning("Failed to publish timezone for \(conversationId) (best-effort): \(error.localizedDescription)")
        }
    }

    public func republishTimezoneForAgentConversations() async {
        let currentTimezone = await currentDeviceTimezone()
        let inboxId = myInboxId
        let agentConversationIds: [String]
        do {
            agentConversationIds = try await databaseReader.read { db in
                let myConversationIds: [String] = try DBMemberProfile
                    .filter(DBMemberProfile.Columns.inboxId == inboxId)
                    .fetchAll(db)
                    .map(\.conversationId)
                return try myConversationIds.filter { conversationId in
                    try OutgoingMessageWriter.hasCurrentAgentMember(db: db, conversationId: conversationId)
                }
            }
        } catch {
            Log.warning("Failed to enumerate agent conversations for timezone republish: \(error.localizedDescription)")
            return
        }

        for conversationId in agentConversationIds {
            guard lastPublishedTimezone(for: conversationId) != currentTimezone else { continue }
            do {
                try await publish(timezone: currentTimezone, conversationId: conversationId)
            } catch {
                Log.warning("Failed to republish timezone for \(conversationId) (best-effort): \(error.localizedDescription)")
            }
        }
    }

    private func publish(timezone: String, conversationId: String) async throws {
        try await profileMetadataWriter.updateMetadata(
            conversationId: conversationId,
            inboxId: myInboxId
        ) { metadata in
            metadata[Constant.timezoneKey] = .string(timezone)
        }
        setLastPublishedTimezone(timezone, for: conversationId)
    }

    @MainActor
    private func currentDeviceTimezone() -> String {
        TimeZone.current.identifier
    }

    // MARK: - Throttle persistence

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private func storageKey(for conversationId: String) -> String {
        "\(Constant.lastPublishedKeyPrefix)\(conversationId)"
    }

    private func lastPublishedTimezone(for conversationId: String) -> String? {
        defaults().string(forKey: storageKey(for: conversationId))
    }

    private func setLastPublishedTimezone(_ timezone: String, for conversationId: String) {
        defaults().set(timezone, forKey: storageKey(for: conversationId))
    }

    private enum Constant {
        static let timezoneKey: String = "timezone"
        static let lastPublishedKeyPrefix: String = "convos.agentTimezone.lastPublished.v1."
    }
}
