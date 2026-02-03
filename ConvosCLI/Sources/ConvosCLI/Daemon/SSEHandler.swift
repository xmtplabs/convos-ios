import ConvosCore
import Foundation
import NIOCore

/// Handles Server-Sent Events streaming for real-time message updates
actor SSEHandler {
    private let context: CLIContext
    private var eventId: Int = 0

    init(context: CLIContext) {
        self.context = context
    }

    /// Create an async stream of SSE events
    func stream() -> AsyncStream<ByteBuffer> {
        AsyncStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }

            Task {
                await self.runStream(continuation: continuation)
            }
        }
    }

    private func runStream(continuation: AsyncStream<ByteBuffer>.Continuation) async {
        do {
            // Send initial connected event
            let connectedEvent = formatSSE(event: "connected", data: ["status": "ok"])
            continuation.yield(ByteBuffer(string: connectedEvent))

            // Initialize messaging service
            let messagingService = await context.session.addInbox()

            do {
                _ = try await messagingService.inboxStateManager.waitForInboxReadyResult()
            } catch {
                let errorEvent = formatSSE(event: "error", data: ["message": "Failed to initialize inbox: \(error.localizedDescription)"])
                continuation.yield(ByteBuffer(string: errorEvent))
                continuation.finish()
                return
            }

            // Get streaming provider
            let streamProvider = messagingService.messageStreamProvider()

            // Stream messages
            for try await message in streamProvider.stream(consentStates: [.allowed, .unknown]) {
                let event = formatMessageEvent(message)
                continuation.yield(ByteBuffer(string: event))
            }

            continuation.finish()
        } catch {
            let errorEvent = formatSSE(event: "error", data: ["message": error.localizedDescription])
            continuation.yield(ByteBuffer(string: errorEvent))
            continuation.finish()
        }
    }

    private func formatMessageEvent(_ message: StreamedMessage) -> String {
        eventId += 1

        let eventType: String
        var data: [String: Any] = [
            "channel": "convos",
            "conversationId": message.conversationId,
            "messageId": message.id,
            "from": message.senderInboxId,
            "timestamp": ISO8601DateFormatter().string(from: message.sentAt)
        ]

        switch message.content {
        case .text(let text):
            eventType = "message"
            data["body"] = text
            data["type"] = "text"

        case .emoji(let emoji):
            eventType = "message"
            data["body"] = emoji
            data["type"] = "emoji"

        case let .reaction(emoji, messageId, action):
            eventType = "reaction"
            data["emoji"] = emoji
            data["targetMessageId"] = messageId
            data["action"] = action == .added ? "added" : "removed"

        case .attachment(let url):
            eventType = "message"
            data["body"] = "[Attachment]"
            data["type"] = "attachment"
            data["attachmentUrl"] = url

        case .attachments(let urls):
            eventType = "message"
            data["body"] = "[Attachments: \(urls.count)]"
            data["type"] = "attachments"
            data["attachmentUrls"] = urls

        case .groupUpdate:
            eventType = "system"
            data["body"] = "[Group updated]"
            data["type"] = "group_update"

        case .unsupported:
            eventType = "system"
            data["body"] = "[Unsupported message type]"
            data["type"] = "unsupported"
        }

        return formatSSE(event: eventType, data: data, id: eventId)
    }

    private func formatSSE(event: String, data: [String: Any], id: Int? = nil) -> String {
        var result = "event: \(event)\n"

        if let id = id {
            result += "id: \(id)\n"
        }

        // Encode data as JSON
        if let jsonData = try? JSONSerialization.data(withJSONObject: data),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            result += "data: \(jsonString)\n"
        }

        result += "\n"
        return result
    }
}

// MARK: - SSE Heartbeat

extension SSEHandler {
    /// Create a stream with periodic heartbeats to keep connection alive
    func streamWithHeartbeat(interval: TimeInterval = 30) -> AsyncStream<ByteBuffer> {
        AsyncStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }

            Task {
                await self.runStreamWithHeartbeat(continuation: continuation, interval: interval)
            }
        }
    }

    private func runStreamWithHeartbeat(continuation: AsyncStream<ByteBuffer>.Continuation, interval: TimeInterval) async {
        // Run message stream and heartbeat concurrently
        await withTaskGroup(of: Void.self) { group in
            // Message stream task
            group.addTask {
                await self.runStream(continuation: continuation)
            }

            // Heartbeat task
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled else { break }

                    let heartbeat = ": heartbeat\n\n"
                    continuation.yield(ByteBuffer(string: heartbeat))
                }
            }

            // Wait for message stream to complete (it runs until cancelled)
            await group.next()
            group.cancelAll()
        }
    }
}
