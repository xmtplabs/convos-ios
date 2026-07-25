import ConvosAppData
import Foundation
@_spi(Unstable) import XMTPiOS

public struct GroupMembershipCapabilitiesDebugInfo: Sendable {
    public struct InstallationEntry: Sendable {
        public let installationId: String
        public let isOwn: Bool
        public let supportsProposals: Bool
        public let capabilitiesKnown: Bool
        public let extensions: [String]
    }

    public struct MemberEntry: Sendable {
        public let inboxId: String
        public let supportsProposals: Bool
        public let installations: [InstallationEntry]
    }

    public let conversationId: String
    public let epoch: UInt64
    public let isActive: Bool
    public let maybeForked: Bool
    public let forkStatus: String
    public let creatorInboxId: String
    public let isMigrated: Bool
    public let eligibleToMigrate: Bool
    public let contextExtensions: [String]
    public let appDataText: String
    public let members: [MemberEntry]

    public var debugText: String {
        let blockingInboxes = members.filter { !$0.supportsProposals }.map(\.inboxId)
        var lines: [String] = [
            "=== group context ===",
            "conversationId: \(conversationId)",
            "epoch: \(epoch)",
            "active member: \(isActive ? "yes" : "no")",
            "forked: \(maybeForked ? "yes" : "no") (\(forkStatus))",
            "creator inbox: \(creatorInboxId)",
            "migrated (proposals enabled): \(isMigrated ? "yes" : "no")",
            "eligible to migrate now: \(eligibleToMigrate ? "yes" : "no")",
            "context extensions (types): \(displayList(contextExtensions))",
            "blocking inboxes: \(blockingInboxes.isEmpty ? "none" : displayList(blockingInboxes))",
            "",
            "=== app data ===",
            appDataText,
            "",
            "=== members (\(members.count)) ==="
        ]
        for member in members {
            let status = member.supportsProposals ? "supports" : "blocking"
            lines.append("  inbox \(member.inboxId) - \(status)")
            for installation in member.installations {
                let support = installation.supportsProposals ? "supports" : "no"
                let own = installation.isOwn ? " (this device)" : ""
                let known = installation.capabilitiesKnown ? "" : " (capabilities unknown)"
                lines.append("    - \(installation.installationId): \(support)\(own)\(known)")
                lines.append("        extensions: \(displayList(installation.extensions))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func displayList(_ values: [String]) -> String {
        values.isEmpty ? "<none>" : values.joined(separator: ", ")
    }
}

public extension XMTPClientProvider {
    /// Snapshot a group's per-member migration capabilities for the debug view.
    ///
    /// Reads the generic `membershipCapabilities()` surface and derives the
    /// proposal-migration answers app-side: the group is migrated when the
    /// context carries the app-data-dictionary extension, and an inbox blocks
    /// migration when one of its installations does not advertise it.
    func groupMembershipCapabilitiesDebugInfo(
        conversationId: String
    ) async throws -> GroupMembershipCapabilitiesDebugInfo {
        guard let xmtpConversation = try await conversation(with: conversationId),
              case .group(let group) = xmtpConversation else {
            throw XMTPClientProviderError.conversationNotFound(id: conversationId)
        }

        let capabilities = try await group.membershipCapabilities()
        let debugInfo = try? await group.getDebugInformation()
        let isActive = (try? group.isActive()) ?? false
        let creator = (try? await group.creatorInboxId()) ?? "<error>"
        let rawAppData = (try? group.appData()) ?? ""
        let appDataSnapshot = ConversationCustomMetadataDebugSnapshot(rawAppData: rawAppData)
        let appDataDictionary: MlsExtensionType = .appDataDictionary

        let members: [GroupMembershipCapabilitiesDebugInfo.MemberEntry] = capabilities.members.map { member in
            let installations: [GroupMembershipCapabilitiesDebugInfo.InstallationEntry] = member.installations.map { installation in
                let supports = installation.capabilitiesKnown && installation.supportedExtensions.contains(appDataDictionary)
                return GroupMembershipCapabilitiesDebugInfo.InstallationEntry(
                    installationId: installation.installationId.hexString,
                    isOwn: installation.isOwn,
                    supportsProposals: supports,
                    capabilitiesKnown: installation.capabilitiesKnown,
                    extensions: installation.supportedExtensions.map { String(describing: $0) }
                )
            }
            let memberSupports = !installations.isEmpty && installations.allSatisfy { $0.supportsProposals }
            return GroupMembershipCapabilitiesDebugInfo.MemberEntry(
                inboxId: member.inboxId,
                supportsProposals: memberSupports,
                installations: installations
            )
        }

        let isMigrated = capabilities.contextExtensions.contains(appDataDictionary)
        let eligibleToMigrate = !members.isEmpty && members.allSatisfy { $0.supportsProposals }

        return GroupMembershipCapabilitiesDebugInfo(
            conversationId: conversationId,
            epoch: debugInfo?.epoch ?? 0,
            isActive: isActive,
            maybeForked: debugInfo?.maybeForked ?? false,
            forkStatus: debugInfo.map { String(describing: $0.commitLogForkStatus) } ?? "<unknown>",
            creatorInboxId: creator,
            isMigrated: isMigrated,
            eligibleToMigrate: eligibleToMigrate,
            contextExtensions: capabilities.contextExtensions.map { String(describing: $0) },
            appDataText: appDataSnapshot.debugText,
            members: members
        )
    }

    /// Enable membership proposals ("migrate" the group) from the debug view.
    ///
    /// Wraps the SDK `UnstableGroup.enableProposals(force:minVersion:)`. When set,
    /// `minVersion` is the minimum libxmtp version an installation must run for
    /// the migration to proceed; installations below it block it. `force`
    /// bypasses the per-member capability precheck (the SDK otherwise hard-fails
    /// when any member's key package can't support proposals).
    func enableProposals(
        conversationId: String,
        force: Bool = false,
        minVersion: String? = nil
    ) async throws {
        guard let xmtpConversation = try await conversation(with: conversationId),
              case .group(let group) = xmtpConversation else {
            throw XMTPClientProviderError.conversationNotFound(id: conversationId)
        }
        try await group.unstable.enableProposals(force: force, minVersion: minVersion)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
