import Foundation
import GRDB
import XMTPiOS

public protocol MemberProfileWriterProtocol {
    func store(memberProfiles: [DBMemberProfile]) async throws
}

class MemberProfileWriter: MemberProfileWriterProtocol {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func store(memberProfiles: [DBMemberProfile]) async throws {
        try await databaseWriter.write { db in
            for memberProfile in memberProfiles {
                let member = Member(inboxId: memberProfile.inboxId)
                try member.save(db)
                try memberProfile.save(db)
            }
        }
    }
}
