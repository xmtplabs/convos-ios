import Foundation
import GRDB

public enum AgentVerificationWriter {
    public static func reverifyUnverifiedAgents(in dbWriter: any DatabaseWriter) async throws {
        let unverifiedAgents = try await dbWriter.read { db in
            try DBMemberProfile
                .filter(DBMemberProfile.Columns.memberKind == DBMemberKind.agent.rawValue)
                .fetchAll(db)
        }

        guard !unverifiedAgents.isEmpty else { return }
        Log.info("[AgentVerification] re-verifying \(unverifiedAgents.count) unverified agent(s)")

        var updatedCount = 0
        for profile in unverifiedAgents {
            let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
            guard verification.isVerified else { continue }

            let updatedKind = DBMemberKind.from(agentVerification: verification)
            try await dbWriter.write { db in
                let updated = profile.with(memberKind: updatedKind)
                try updated.save(db)
            }
            updatedCount += 1
        }

        if updatedCount > 0 {
            Log.info("[AgentVerification] upgraded \(updatedCount) agent(s) to verified")
        }
    }
}
