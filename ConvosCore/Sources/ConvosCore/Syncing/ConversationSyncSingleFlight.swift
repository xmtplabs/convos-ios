import Foundation

/// Coalesces concurrent syncs of the same conversation.
///
/// A newly created group is processed twice within the same instant: once by
/// the `ConversationStateMachine` that created it and once by `SyncingManager`'s
/// conversation stream echoing it back. Each owns its own `StreamProcessor`,
/// so the coalescing lives here, shared process-wide, instead of inside either
/// actor. The registry doubles as the "anything still in flight?" signal the
/// backgrounding path checks before dropping the SQLCipher connection.
actor ConversationSyncSingleFlight {
    static let shared: ConversationSyncSingleFlight = ConversationSyncSingleFlight()

    private struct InFlightSync {
        let token: UUID
        let clientConversationId: String?
        let task: Task<Void, any Error>
    }

    private var inFlight: [String: InFlightSync] = [:]

    /// Runs `operation` unless an equivalent sync for the same conversation is
    /// already in flight, in which case the caller awaits that sync instead.
    /// A caller carrying a `clientConversationId` the in-flight sync doesn't
    /// know about still runs its own pass afterwards, so the draft-row mapping
    /// is never dropped by coalescing.
    func run(
        conversationId: String,
        clientConversationId: String?,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        while let existing = inFlight[conversationId] {
            if clientConversationId == nil || existing.clientConversationId == clientConversationId {
                try await existing.task.value
                return
            }
            // The in-flight sync doesn't carry this caller's client
            // conversation id mapping; wait it out, then loop in case another
            // sync started while we waited.
            try? await existing.task.value
        }

        let token = UUID()
        let task = Task { try await operation() }
        inFlight[conversationId] = InFlightSync(
            token: token,
            clientConversationId: clientConversationId,
            task: task
        )
        defer {
            if inFlight[conversationId]?.token == token {
                inFlight[conversationId] = nil
            }
        }
        try await task.value
    }

    /// Waits (bounded) for in-flight syncs to finish. The backgrounding path
    /// calls this before dropping the SQLCipher connection so in-flight work
    /// completes instead of burning retries on "Pool needs to reconnect".
    func waitForInFlight(timeoutSeconds: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !inFlight.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !inFlight.isEmpty {
            Log.warning("Continuing with \(inFlight.count) conversation sync(s) still in flight after \(timeoutSeconds)s")
        }
    }
}
