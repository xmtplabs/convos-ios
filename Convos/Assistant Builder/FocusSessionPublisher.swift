import ConvosCore
import ConvosLogging
import Foundation

/// Sender-side publisher for live-typing payloads. Owns the local revision
/// counter and a debounced send so a fast typist doesn't ship one XMTP
/// message per keystroke.
///
/// Design choices (from plan §6):
///   - Per-keystroke `publish(text:)`, debounced to ~50ms. The latest
///     pending text wins; intermediate snapshots are discarded.
///   - Each send increments `revision` by 1, monotonic per (sessionId,
///     senderInboxId). Receivers drop stale revisions.
///   - `clear()` ships a StreamingClear with revision = next, and the
///     wall-clock-driven 600ms receiver delay lives in the writer/view
///     layer (this publisher just emits the message).
@MainActor
final class FocusSessionPublisher {
    private let messagingService: AnyMessagingService
    private let conversationId: String
    private let sessionId: String
    private let senderInboxId: String

    private var revision: UInt32 = 0
    private var pendingText: String?
    private var debounceTask: Task<Void, Never>?

    private let debounceNanos: UInt64 = 50_000_000

    init(
        messagingService: AnyMessagingService,
        conversationId: String,
        sessionId: String,
        senderInboxId: String
    ) {
        self.messagingService = messagingService
        self.conversationId = conversationId
        self.sessionId = sessionId
        self.senderInboxId = senderInboxId
    }

    /// Schedule a snapshot send. Repeated calls within 50ms collapse — only
    /// the most recent text gets shipped.
    func publish(text: String) {
        pendingText = text
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.debounceNanos ?? 50_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Cancel any pending debounce and ship a StreamingClear immediately.
    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingText = nil
        revision &+= 1
        let payload = StreamingClear(
            sessionId: sessionId,
            senderInboxId: senderInboxId,
            revision: revision
        )
        let messagingService = messagingService
        let conversationId = conversationId
        Task {
            do {
                try await messagingService.sendStreamingClear(payload, for: conversationId)
            } catch {
                Log.warning("Failed sending StreamingClear: \(error.localizedDescription)")
            }
        }
    }

    private func flush() async {
        guard let text = pendingText else { return }
        pendingText = nil
        revision &+= 1
        let payload = StreamingText(
            sessionId: sessionId,
            senderInboxId: senderInboxId,
            revision: revision,
            text: text
        )
        do {
            try await messagingService.sendStreamingText(payload, for: conversationId)
        } catch {
            Log.warning("Failed sending StreamingText: \(error.localizedDescription)")
        }
    }
}
