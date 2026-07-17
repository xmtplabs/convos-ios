@testable import ConvosCore
import Foundation
import Testing

// MARK: - Seed Helpers

private let benchCurrentUser: ConversationMember = .mock(isCurrentUser: true)

private func makeBenchSenders(count: Int) -> [ConversationMember] {
    var senders: [ConversationMember] = [benchCurrentUser]
    for i in 1..<count {
        senders.append(ConversationMember(
            profile: Profile(inboxId: "sender-\(i)", conversationId: "bench-conv", name: "User \(i)", avatar: nil),
            role: .member,
            isCurrentUser: false
        ))
    }
    return senders
}

private func seedMessages(
    count: Int,
    senders: [ConversationMember],
    timeSpreadSeconds: Double = 30,
    attachmentEvery: Int = 0,
    updateEvery: Int = 0,
    replyEvery: Int = 0,
    reactionsPerMessage: Int = 0
) -> [AnyMessage] {
    let now = Date()
    var messages: [AnyMessage] = []
    messages.reserveCapacity(count)

    for i in 0..<count {
        let sender: ConversationMember = senders[i % senders.count]
        let date: Date = now.addingTimeInterval(Double(i) * timeSpreadSeconds)

        if updateEvery > 0 && i > 0 && i % updateEvery == 0 {
            let addedMember = ConversationMember(
                profile: Profile(inboxId: "added-\(i)", conversationId: "bench-conv", name: "Added \(i)", avatar: nil),
                role: .member,
                isCurrentUser: false
            )
            messages.append(.message(Message(
                id: "update-\(i)",
                sender: sender,
                source: .incoming,
                status: .published,
                content: .update(ConversationUpdate(
                    creator: sender,
                    addedMembers: [addedMember],
                    removedMembers: [],
                    metadataChanges: []
                )),
                date: date,
                reactions: []
            ), .existing))
            continue
        }

        if attachmentEvery > 0 && i > 0 && i % attachmentEvery == 0 {
            messages.append(.message(Message(
                id: "msg-\(i)",
                sender: sender,
                source: sender.isCurrentUser ? .outgoing : .incoming,
                status: .published,
                content: .attachment(HydratedAttachment(key: "https://example.com/\(i).jpg")),
                date: date,
                reactions: []
            ), .existing))
            continue
        }

        if replyEvery > 0 && i > 0 && i % replyEvery == 0, let sourceMsg = messages.last {
            let parentSender: ConversationMember = senders[(i + 1) % senders.count]
            let parentMessage = Message(
                id: "parent-\(i)",
                sender: parentSender,
                source: parentSender.isCurrentUser ? .outgoing : .incoming,
                status: .published,
                content: .text("Parent of reply \(i)"),
                date: date.addingTimeInterval(-60),
                reactions: []
            )
            messages.append(.reply(MessageReply(
                id: "msg-\(i)",
                sender: sender,
                source: sender.isCurrentUser ? .outgoing : .incoming,
                status: .published,
                content: .text("Reply \(i)"),
                date: date,
                parentMessage: parentMessage,
                reactions: []
            ), .existing))
            continue
        }

        var reactions: [MessageReaction] = []
        if reactionsPerMessage > 0 {
            let emojis = ["👍", "❤️", "😂", "🔥", "👀"]
            for r in 0..<reactionsPerMessage {
                let reactorSender: ConversationMember = senders[(i + r + 1) % senders.count]
                reactions.append(MessageReaction(
                    id: "reaction-\(i)-\(r)",
                    sender: reactorSender,
                    source: reactorSender.isCurrentUser ? .outgoing : .incoming,
                    status: .published,
                    content: .emoji(emojis[r % emojis.count]),
                    date: date,
                    emoji: emojis[r % emojis.count]
                ))
            }
        }

        messages.append(.message(Message(
            id: "msg-\(i)",
            sender: sender,
            source: sender.isCurrentUser ? .outgoing : .incoming,
            status: .published,
            content: .text("Message \(i) from \(sender.profile.displayName)"),
            date: date,
            reactions: reactions
        ), .existing))
    }

    return messages
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
    return sorted[mid]
}

// MARK: - Benchmark Tests

struct MessagesListProcessorBenchmarkTests {
    @Test("Benchmark: 50 messages, 2 senders, text only")
    func benchmark50TextOnly() {
        let senders = makeBenchSenders(count: 2)
        let messages = seedMessages(count: 50, senders: senders)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 50 msgs (2 senders, text): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: 200 messages, 5 senders, text only")
    func benchmark200TextOnly() {
        let senders = makeBenchSenders(count: 5)
        let messages = seedMessages(count: 200, senders: senders)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (5 senders, text): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: 200 messages with attachments every 10th")
    func benchmark200WithAttachments() {
        let senders = makeBenchSenders(count: 5)
        let messages = seedMessages(count: 200, senders: senders, attachmentEvery: 10)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (attachments every 10): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: 200 messages with updates every 20th")
    func benchmark200WithUpdates() {
        let senders = makeBenchSenders(count: 5)
        let messages = seedMessages(count: 200, senders: senders, updateEvery: 20)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (updates every 20): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: 200 messages with replies every 5th")
    func benchmark200WithReplies() {
        let senders = makeBenchSenders(count: 5)
        let messages = seedMessages(count: 200, senders: senders, replyEvery: 5)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (replies every 5): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: 200 messages with reactions (3 per msg)")
    func benchmark200WithReactions() {
        let senders = makeBenchSenders(count: 5)
        let messages = seedMessages(count: 200, senders: senders, reactionsPerMessage: 3)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (3 reactions/msg): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: 200 messages with hour gaps (many date separators)")
    func benchmark200WithDateGaps() {
        let senders = makeBenchSenders(count: 3)
        let messages = seedMessages(count: 200, senders: senders, timeSpreadSeconds: 3700)

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (hour gaps, many separators): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: worst-case alternating senders (200 msgs, max groups)")
    func benchmarkAlternatingSenders() {
        let senders = makeBenchSenders(count: 2)
        let now = Date()
        let messages: [AnyMessage] = (0..<200).map { i in
            let sender: ConversationMember = senders[i % 2]
            return .message(Message(
                id: "msg-\(i)",
                sender: sender,
                source: sender.isCurrentUser ? .outgoing : .incoming,
                status: .published,
                content: .text("Msg \(i)"),
                date: now.addingTimeInterval(Double(i) * 10),
                reactions: []
            ), .existing)
        }

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (alternating senders): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: heavy mixed scenario (500 msgs, all features)")
    func benchmarkHeavyMixed() {
        let senders = makeBenchSenders(count: 10)
        let messages = seedMessages(
            count: 500,
            senders: senders,
            timeSpreadSeconds: 120,
            attachmentEvery: 15,
            updateEvery: 50,
            replyEvery: 7,
            reactionsPerMessage: 2
        )

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 500 msgs (heavy mixed): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }

    @Test("Benchmark: onlyVisibleToSender tracking with member changes")
    func benchmarkOnlyVisibleToSender() {
        let senders = makeBenchSenders(count: 3)
        let messages = seedMessages(
            count: 200,
            senders: senders,
            updateEvery: 25
        )

        var times: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 0)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
            times.append(elapsed)
            #expect(!result.isEmpty)
        }
        let med = median(times)
        let min = times.min() ?? 0
        print("[BENCHMARK] Process 200 msgs (onlyVisibleToSender, updates every 25): median=\(String(format: "%.0f", med))µs min=\(String(format: "%.0f", min))µs")
    }
}
