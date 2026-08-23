import ConvosCore
import Foundation

/// Local preference + global-profile publisher for the intentionally narrow
/// "which agent providers do you use?" social signal.
enum SocialAgentProfileSharing {
    private static let defaultsKeyPrefix: String = "external-agents.profile-sharing-enabled"

    static func isEnabled(
        session: any SessionManagerProtocol,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = defaultsKey(session: session) else { return false }
        return defaults.bool(forKey: key)
    }

    /// Publishes provider names through the canonical global profile path.
    /// That path lazily carries the metadata to each conversation; no agent
    /// credential, request, result, context, or activity is part of this map.
    @MainActor
    static func publish(
        isEnabled: Bool,
        session: any SessionManagerProtocol
    ) async throws {
        let messagingService = session.messagingServiceSync()
        let existing = try messagingService.myGlobalProfileRepository().fetch()?.metadata
        var metadata: ProfileMetadata = existing ?? [:]
        SocialAgentProfileMetadata.update(
            &metadata,
            isVisible: isEnabled,
            providerIds: AddedExternalAgentStore.providers(session: session).map(\.rawValue)
        )
        try await messagingService.profilesRepository().publishMyProfileMetadata(
            metadata.isEmpty ? nil : metadata
        )
        guard let key = defaultsKey(session: session) else {
            throw SocialAgentProfileSharingError.identityUnavailable
        }
        UserDefaults.standard.set(isEnabled, forKey: key)
    }

    /// Refreshes an already-public provider list after a new personal agent is
    /// connected. Sharing remains strictly opt-in.
    @MainActor
    static func republishIfEnabled(session: any SessionManagerProtocol) async {
        guard isEnabled(session: session) else { return }
        do {
            try await publish(isEnabled: true, session: session)
        } catch {
            Log.error("Failed publishing connected-agent profile identities: \(error.localizedDescription)")
        }
    }

    static func resetAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
            where key == defaultsKeyPrefix || key.hasPrefix("\(defaultsKeyPrefix).") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func defaultsKey(session: any SessionManagerProtocol) -> String? {
        guard case .authorized(let inboxId) = session.messagingServiceSync().state else {
            return nil
        }
        return "\(defaultsKeyPrefix).\(inboxId)"
    }
}

private enum SocialAgentProfileSharingError: Error {
    case identityUnavailable
}
