@testable import ConvosCore
import Foundation
import GRDB
import Testing

private struct MessageSenderOnly: Codable, FetchableRecord, Hashable {
    let message: DBMessage
    let messageSender: DBConversationMemberProfileWithRole
}

struct MessagesRepositoryBenchmarkTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(configuration: {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return config
        }())
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedConversation(
        db: Database,
        conversationId: String,
        currentInboxId: String,
        memberCount: Int,
        messageCount: Int,
        reactionsPerMessage: Int,
        replyCount: Int
    ) throws -> [String] {
        let now = Date()
        let clientId = "client-\(UUID().uuidString)"
        let creatorInboxId = currentInboxId

        try DBMember(inboxId: creatorInboxId).insert(db)

        var memberInboxIds: [String] = [creatorInboxId]
        for i in 1..<memberCount {
            let inboxId = "member-\(i)-\(UUID().uuidString)"
            try DBMember(inboxId: inboxId).insert(db)
            memberInboxIds.append(inboxId)
        }

        try DBConversation(
            id: conversationId,
            inboxId: currentInboxId,
            clientId: clientId,
            clientConversationId: "client-conv-\(conversationId)",
            inviteTag: "tag-\(conversationId)",
            creatorId: creatorInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: now,
            name: "Test Conversation",
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            imageLastRenewed: nil,
            isUnused: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: now,
            isMuted: false,
            pinnedOrder: nil
        ).insert(db)

        for (i, inboxId) in memberInboxIds.enumerated() {
            let role: MemberRole = i == 0 ? .superAdmin : .member
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: role,
                consent: .allowed,
                createdAt: now
            ).insert(db)

            try DBMemberProfile(
                conversationId: conversationId,
                inboxId: inboxId,
                name: "User \(i)",
                avatar: nil
            ).insert(db)
        }

        var messageIds: [String] = []
        for i in 0..<messageCount {
            let msgId = "msg-\(i)-\(UUID().uuidString)"
            let senderId = memberInboxIds[i % memberInboxIds.count]
            let dateNs = Int64(i) * 1_000_000_000
            try DBMessage(
                id: msgId,
                clientMessageId: msgId,
                conversationId: conversationId,
                senderId: senderId,
                dateNs: dateNs,
                date: now.addingTimeInterval(Double(i)),
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "Message \(i) from user \(senderId.prefix(8))",
                emoji: nil,
                invite: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)
            messageIds.append(msgId)
        }

        let emojis = ["👍", "❤️", "😂", "🔥", "👀"]
        for i in 0..<messageCount {
            for r in 0..<reactionsPerMessage {
                let reactorId = memberInboxIds[(i + r + 1) % memberInboxIds.count]
                let reactionId = "reaction-\(i)-\(r)-\(UUID().uuidString)"
                try DBMessage(
                    id: reactionId,
                    clientMessageId: reactionId,
                    conversationId: conversationId,
                    senderId: reactorId,
                    dateNs: Int64(messageCount + i * reactionsPerMessage + r) * 1_000_000_000,
                    date: now.addingTimeInterval(Double(messageCount + i * reactionsPerMessage + r)),
                    status: .published,
                    messageType: .reaction,
                    contentType: .emoji,
                    text: nil,
                    emoji: emojis[r % emojis.count],
                    invite: nil,
                    sourceMessageId: messageIds[i],
                    attachmentUrls: [],
                    update: nil
                ).insert(db)
            }
        }

        for r in 0..<replyCount {
            let sourceIdx = r % messageCount
            let replyId = "reply-\(r)-\(UUID().uuidString)"
            let senderId = memberInboxIds[(sourceIdx + 1) % memberInboxIds.count]
            try DBMessage(
                id: replyId,
                clientMessageId: replyId,
                conversationId: conversationId,
                senderId: senderId,
                dateNs: Int64(messageCount + messageCount * reactionsPerMessage + r) * 1_000_000_000,
                date: now.addingTimeInterval(Double(messageCount + messageCount * reactionsPerMessage + r)),
                status: .published,
                messageType: .reply,
                contentType: .text,
                text: "Reply \(r) to message \(sourceIdx)",
                emoji: nil,
                invite: nil,
                sourceMessageId: messageIds[sourceIdx],
                attachmentUrls: [],
                update: nil
            ).insert(db)
        }

        return messageIds
    }

    @Test("Benchmark: fetchInitial with 50 messages, 5 reactions each, 5 members (pageSize=50)")
    func benchmarkFetchInitial50Messages() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-50"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 50,
                reactionsPerMessage: 5,
                replyCount: 3
            )
        }

        let repo = MessagesRepository(
            dbReader: dbQueue,
            conversationId: conversationId,
            pageSize: 50
        )

        var times: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            let messages = try repo.fetchInitial()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
            #expect(messages.count > 0, "Should have messages")
        }

        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min() ?? 0
        let max = times.max() ?? 0
        print("[BENCHMARK] fetchInitial(50 msgs, 250 reactions, 3 replies, pageSize=50): avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms max=\(String(format: "%.1f", max))ms")
    }

    @Test("Benchmark: fetchInitial with 150 messages, 5 reactions each, 5 members (pageSize=150)")
    func benchmarkFetchInitial150Messages() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-150"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 150,
                reactionsPerMessage: 5,
                replyCount: 5
            )
        }

        let repo = MessagesRepository(
            dbReader: dbQueue,
            conversationId: conversationId,
            pageSize: 150
        )

        var times: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            let messages = try repo.fetchInitial()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
            #expect(messages.count > 0, "Should have messages")
        }

        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min() ?? 0
        let max = times.max() ?? 0
        print("[BENCHMARK] fetchInitial(150 msgs, 750 reactions, 5 replies, pageSize=150): avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms max=\(String(format: "%.1f", max))ms")
    }

    @Test("Benchmark: fetchInitial with 150 messages, 5 reactions each, 5 members (pageSize=50)")
    func benchmarkFetchInitial150MessagesPageSize50() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-150-p50"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 150,
                reactionsPerMessage: 5,
                replyCount: 5
            )
        }

        let repo = MessagesRepository(
            dbReader: dbQueue,
            conversationId: conversationId,
            pageSize: 50
        )

        var times: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            let messages = try repo.fetchInitial()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
            #expect(messages.count > 0, "Should have messages")
        }

        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min() ?? 0
        let max = times.max() ?? 0
        print("[BENCHMARK] fetchInitial(150 msgs in DB, pageSize=50): avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms max=\(String(format: "%.1f", max))ms")
    }

    @Test("Benchmark: detailedConversationQuery vs lightweight for message detail view")
    func benchmarkConversationQueryComparison() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-query"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 100,
                reactionsPerMessage: 3,
                replyCount: 2
            )
        }

        var detailedTimes: [Double] = []
        var lightweightTimes: [Double] = []

        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            try dbQueue.read { db in
                _ = try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .detailedConversationQuery()
                    .fetchOne(db)
            }
            detailedTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            try dbQueue.read { db in
                _ = try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .including(
                        required: DBConversation.creator
                            .forKey("conversationCreator")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .including(required: DBConversation.localState)
                    .including(
                        all: DBConversation._members
                            .forKey("conversationMembers")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .asRequest(of: DBConversationDetails.self)
                    .fetchOne(db)
            }
            lightweightTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let avgDetailed = detailedTimes.reduce(0, +) / Double(detailedTimes.count)
        let avgLightweight = lightweightTimes.reduce(0, +) / Double(lightweightTimes.count)
        print("[BENCHMARK] ConvQuery detailed: avg=\(String(format: "%.1f", avgDetailed))ms min=\(String(format: "%.1f", detailedTimes.min()!))ms")
        print("[BENCHMARK] ConvQuery lightweight: avg=\(String(format: "%.1f", avgLightweight))ms min=\(String(format: "%.1f", lightweightTimes.min()!))ms")
        print("[BENCHMARK] ConvQuery speedup: \(String(format: "%.1f", avgDetailed / avgLightweight))x")
    }

    @Test("Benchmark: fetchInitial with 300 messages, 3 reactions each, 10 members (pageSize=50)")
    func benchmarkFetchInitialHeavy() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-heavy"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 10,
                messageCount: 300,
                reactionsPerMessage: 3,
                replyCount: 10
            )
        }

        let repo50 = MessagesRepository(
            dbReader: dbQueue,
            conversationId: conversationId,
            pageSize: 50
        )
        let repo150 = MessagesRepository(
            dbReader: dbQueue,
            conversationId: conversationId,
            pageSize: 150
        )

        var times50: [Double] = []
        var times150: [Double] = []

        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try repo50.fetchInitial()
            times50.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try repo150.fetchInitial()
            times150.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let avg50 = times50.reduce(0, +) / Double(times50.count)
        let avg150 = times150.reduce(0, +) / Double(times150.count)
        let speedup = avg150 / avg50
        print("[BENCHMARK] Heavy pageSize=50: avg=\(String(format: "%.1f", avg50))ms min=\(String(format: "%.1f", times50.min()!))ms max=\(String(format: "%.1f", times50.max()!))ms")
        print("[BENCHMARK] Heavy pageSize=150: avg=\(String(format: "%.1f", avg150))ms min=\(String(format: "%.1f", times150.min()!))ms max=\(String(format: "%.1f", times150.max()!))ms")
        print("[BENCHMARK] Heavy speedup: \(String(format: "%.1f", speedup))x faster with pageSize=50")
    }

    @Test("Benchmark: default pageSize is now 50")
    func benchmarkDefaultPageSize() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-default-ps"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 200,
                reactionsPerMessage: 3,
                replyCount: 5
            )
        }

        let repo = MessagesRepository(
            dbReader: dbQueue,
            conversationId: conversationId
        )

        var times: [Double] = []
        var messageCount: Int = 0
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            let messages = try repo.fetchInitial()
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            messageCount = messages.count
        }

        let avg = times.reduce(0, +) / Double(times.count)
        print("[BENCHMARK] Default pageSize (200 msgs in DB): avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", times.min()!))ms msgs=\(messageCount)")
        #expect(messageCount <= 50, "Default page should load at most 50 messages worth of content")
    }

    @Test("Benchmark: sourceMessage join cost")
    func benchmarkSourceMessageJoinCost() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-src"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 100,
                reactionsPerMessage: 5,
                replyCount: 10
            )
        }

        var withSourceTimes: [Double] = []
        var noSourceTimes: [Double] = []

        for _ in 0..<10 {
            try dbQueue.read { db in
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
                    .order(DBMessage.Columns.dateNs.desc)
                    .limit(50)
                    .including(
                        required: DBMessage.sender
                            .forKey("messageSender")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .including(optional: DBMessage.sourceMessage)
                    .asRequest(of: MessageWithDetailsLite.self)
                    .fetchAll(db)
                withSourceTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

                let t1 = CFAbsoluteTimeGetCurrent()
                _ = try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
                    .order(DBMessage.Columns.dateNs.desc)
                    .limit(50)
                    .including(
                        required: DBMessage.sender
                            .forKey("messageSender")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .asRequest(of: MessageSenderOnly.self)
                    .fetchAll(db)
                noSourceTimes.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
            }
        }

        let avgWith = withSourceTimes.reduce(0, +) / Double(withSourceTimes.count)
        let avgWithout = noSourceTimes.reduce(0, +) / Double(noSourceTimes.count)
        print("[BENCHMARK] MsgQuery with sourceMessage join: avg=\(String(format: "%.1f", avgWith))ms")
        print("[BENCHMARK] MsgQuery without sourceMessage: avg=\(String(format: "%.1f", avgWithout))ms")
        print("[BENCHMARK] sourceMessage join cost: \(String(format: "%.1f", avgWith - avgWithout))ms")

        var rawTimes: [Double] = []
        for _ in 0..<10 {
            try dbQueue.read { db in
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
                    .order(DBMessage.Columns.dateNs.desc)
                    .limit(50)
                    .fetchAll(db)
                rawTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
        let avgRaw = rawTimes.reduce(0, +) / Double(rawTimes.count)
        print("[BENCHMARK] MsgQuery raw (no joins): avg=\(String(format: "%.1f", avgRaw))ms")
        print("[BENCHMARK] Sender join cost: \(String(format: "%.1f", avgWithout - avgRaw))ms")
    }

    @Test("Benchmark: breakdown of composeMessages sub-queries")
    func benchmarkComposeMessagesBreakdown() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-bench-breakdown"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 100,
                reactionsPerMessage: 5,
                replyCount: 3
            )
        }

        for _ in 0..<3 {
            try dbQueue.read { db in
                let t0 = CFAbsoluteTimeGetCurrent()

                _ = try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .including(
                        required: DBConversation.creator
                            .forKey("conversationCreator")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .including(required: DBConversation.localState)
                    .including(
                        all: DBConversation._members
                            .forKey("conversationMembers")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .asRequest(of: DBConversationDetails.self)
                    .fetchOne(db)
                let t1 = CFAbsoluteTimeGetCurrent()

                _ = try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversationId)
                    .select([DBConversationMember.Columns.role])
                    .including(required: DBConversationMember.memberProfile)
                    .asRequest(of: DBConversationMemberProfileWithRole.self)
                    .fetchAll(db)
                let t2 = CFAbsoluteTimeGetCurrent()

                let msgs = try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
                    .order(DBMessage.Columns.dateNs.desc)
                    .limit(50)
                    .including(
                        required: DBMessage.sender
                            .forKey("messageSender")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .including(all: DBMessage.reactions)
                    .including(optional: DBMessage.sourceMessage)
                    .asRequest(of: MessageWithDetails.self)
                    .fetchAll(db)
                let t3 = CFAbsoluteTimeGetCurrent()

                let noAssocStart = CFAbsoluteTimeGetCurrent()
                let msgsLite = try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
                    .order(DBMessage.Columns.dateNs.desc)
                    .limit(50)
                    .including(
                        required: DBMessage.sender
                            .forKey("messageSender")
                            .select([DBConversationMember.Columns.role])
                            .including(required: DBConversationMember.memberProfile)
                    )
                    .including(optional: DBMessage.sourceMessage)
                    .asRequest(of: MessageWithDetailsLite.self)
                    .fetchAll(db)
                let noAssocMs = (CFAbsoluteTimeGetCurrent() - noAssocStart) * 1000

                let reactionsStart = CFAbsoluteTimeGetCurrent()
                let msgIds = msgsLite.map { $0.message.id }
                let allReactions = try DBMessage
                    .filter(msgIds.contains(DBMessage.Columns.sourceMessageId))
                    .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                    .fetchAll(db)
                let batchReactMs = (CFAbsoluteTimeGetCurrent() - reactionsStart) * 1000

                let totalNew = noAssocMs + batchReactMs
                let totalOld = (t3 - t2) * 1000
                print("[BENCHMARK] Breakdown: conv=\(String(format: "%.1f", (t1-t0)*1000))ms members=\(String(format: "%.1f", (t2-t1)*1000))ms")
                print("[BENCHMARK] OLD msgs+reactions(including all): \(String(format: "%.1f", totalOld))ms")
                print("[BENCHMARK] NEW msgs-no-assoc=\(String(format: "%.1f", noAssocMs))ms + batchReactions=\(String(format: "%.1f", batchReactMs))ms = \(String(format: "%.1f", totalNew))ms")
                print("[BENCHMARK] Reactions speedup: \(String(format: "%.1f", totalOld / totalNew))x (fetched=\(msgsLite.count) reactions=\(allReactions.count))")
            }
        }
    }

    @Test("Benchmark: end-to-end message load times at various scales")
    func benchmarkEndToEnd() throws {
        let scenarios: [(msgs: Int, reactions: Int, members: Int, label: String)] = [
            (20, 2, 3, "Light (20 msgs, 2 reactions/msg, 3 members)"),
            (50, 3, 5, "Medium (50 msgs, 3 reactions/msg, 5 members)"),
            (100, 5, 5, "Heavy (100 msgs, 5 reactions/msg, 5 members)"),
            (200, 5, 10, "Extreme (200 msgs, 5 reactions/msg, 10 members)")
        ]

        for scenario in scenarios {
            let dbQueue = try makeDatabase()
            let conversationId = "conv-e2e-\(scenario.msgs)"
            let currentInboxId = "current-user-inbox"

            try dbQueue.write { db in
                _ = try seedConversation(
                    db: db,
                    conversationId: conversationId,
                    currentInboxId: currentInboxId,
                    memberCount: scenario.members,
                    messageCount: scenario.msgs,
                    reactionsPerMessage: scenario.reactions,
                    replyCount: Swift.min(5, scenario.msgs / 10)
                )
            }

            let repo = MessagesRepository(
                dbReader: dbQueue,
                conversationId: conversationId
            )

            var times: [Double] = []
            var msgCount: Int = 0
            for _ in 0..<10 {
                let start = CFAbsoluteTimeGetCurrent()
                let messages = try repo.fetchInitial()
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                msgCount = messages.count
            }

            let avg = times.reduce(0, +) / Double(times.count)
            let min = times.min() ?? 0
            print("[BENCHMARK] E2E \(scenario.label): avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms msgs=\(msgCount)")
        }
    }

    @Test("Benchmark: simulated full ConversationViewModel.init path (old vs new)")
    func benchmarkFullInitPath() throws {
        let dbQueue = try makeDatabase()
        let conversationId = "conv-full-init"
        let currentInboxId = "current-user-inbox"

        try dbQueue.write { db in
            _ = try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                memberCount: 5,
                messageCount: 150,
                reactionsPerMessage: 5,
                replyCount: 5
            )
        }

        var oldPathTimes: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            let repo = MessagesRepository(dbReader: dbQueue, conversationId: conversationId, pageSize: 150)
            _ = try repo.fetchInitial()
            try dbQueue.read { db in
                _ = try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .detailedConversationQuery()
                    .fetchOne(db)
            }
            oldPathTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        var newPathTimes: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            let repo = MessagesRepository(dbReader: dbQueue, conversationId: conversationId, pageSize: 50)
            _ = try repo.fetchInitial()
            newPathTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let avgOld = oldPathTimes.reduce(0, +) / Double(oldPathTimes.count)
        let avgNew = newPathTimes.reduce(0, +) / Double(newPathTimes.count)
        let speedup = avgOld / avgNew
        print("[BENCHMARK] Full init OLD (pageSize=150 + detailedQuery): avg=\(String(format: "%.1f", avgOld))ms min=\(String(format: "%.1f", oldPathTimes.min()!))ms")
        print("[BENCHMARK] Full init NEW (pageSize=50, no conv query): avg=\(String(format: "%.1f", avgNew))ms min=\(String(format: "%.1f", newPathTimes.min()!))ms")
        print("[BENCHMARK] Full init speedup: \(String(format: "%.1f", speedup))x")
    }
}
