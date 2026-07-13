import Foundation
import GRDB

public enum AgentVerificationWriter {
    public static func reverifyUnverifiedAgents(in dbWriter: any DatabaseWriter) async throws {
        let unverifiedAgents = try await dbWriter.read { db in
            try DBProfile
                .filter(DBProfile.Columns.memberKind == DBMemberKind.agent.rawValue)
                .fetchAll(db)
        }

        guard !unverifiedAgents.isEmpty else { return }
        Log.info("[AgentVerification] re-verifying \(unverifiedAgents.count) unverified agent(s)")

        var updatedCount = 0
        for profile in unverifiedAgents {
            let hydrated = Profile.from(profile: profile, avatar: nil, inboxId: profile.inboxId, conversationId: "")
            let verification = hydrated.verifyCachedAgentAttestation()
            guard verification.isVerified else { continue }

            let updatedKind = DBMemberKind.from(agentVerification: verification)
            try await dbWriter.write { db in
                var updated = profile
                updated.memberKind = updatedKind
                try updated.save(db)

                guard verification.isConvosAgent else { return }
                // `DBProfile` is per-inbox, so mark every conversation the agent
                // is a member of (the legacy per-conversation row marked just one).
                let conversationIds = try DBConversationMember
                    .filter(DBConversationMember.Columns.inboxId == updated.inboxId)
                    .fetchAll(db)
                    .map(\.conversationId)
                for conversationId in conversationIds {
                    guard let conversation = try DBConversation.fetchOne(db, id: conversationId),
                          !conversation.hasHadVerifiedAgent else { continue }
                    try conversation.with(hasHadVerifiedAgent: true).save(db)
                }
            }
            updatedCount += 1
        }

        if updatedCount > 0 {
            Log.info("[AgentVerification] upgraded \(updatedCount) agent(s) to verified")
        }
    }
}
