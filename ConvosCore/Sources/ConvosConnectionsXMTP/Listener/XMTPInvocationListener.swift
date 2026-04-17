import ConvosConnections
import Foundation
@preconcurrency import XMTPiOS

/// Routes incoming XMTP messages carrying `ConnectionInvocation` content into the
/// package's `ConnectionsManager`.
///
/// Deliberately not a subscriber — the host is expected to call `processIncoming` from
/// its own decoded-message dispatch (e.g. from `SyncingManager`'s stream handler). This
/// avoids spawning a parallel `conversations.streamAllMessages` subscription that would
/// collide with the single-inbox refactor (PR 713).
///
/// Schema version skew is handled here, not in the manager: invocations with a schema
/// version newer than the package knows about bypass the manager entirely and reply with
/// a synthetic `executionFailed` result so the agent gets a structured no.
public final class XMTPInvocationListener: @unchecked Sendable {
    private let manager: ConnectionsManager
    private let delivery: any ConnectionDelivering

    /// The delivery parameter is typed as `ConnectionDelivering` rather than
    /// `XMTPConnectionDelivery` specifically so tests can swap in a recording double.
    /// Production callers pass their `XMTPConnectionDelivery` instance — usually the same
    /// one they also hand to `ConnectionsManager`'s constructor.
    public init(manager: ConnectionsManager, delivery: any ConnectionDelivering) {
        self.manager = manager
        self.delivery = delivery
    }

    /// Process a decoded XMTP message. No-ops for content types that aren't ours.
    public func processIncoming(message: DecodedMessage, conversationId: String) async {
        let encoded: EncodedContent
        do {
            encoded = try message.encodedContent
        } catch {
            return
        }
        guard encoded.type == ContentTypeConnectionInvocation else { return }

        let invocation: ConnectionInvocation
        do {
            invocation = try ConnectionInvocationCodec().decode(content: encoded)
        } catch {
            // No invocationId available — can't reply. Host logging should pick this up.
            return
        }

        await handle(invocation: invocation, conversationId: conversationId)
    }

    /// Visible for testing. Schema-version gate + manager routing, without the XMTP
    /// decoding step. Exercised by the public `processIncoming` after decoding.
    internal func handle(invocation: ConnectionInvocation, conversationId: String) async {
        if invocation.schemaVersion > ConnectionInvocation.currentSchemaVersion {
            let result = ConnectionInvocationResult(
                invocationId: invocation.invocationId,
                kind: invocation.kind,
                actionName: invocation.action.name,
                status: .executionFailed,
                errorMessage: "unsupported schema version \(invocation.schemaVersion)"
            )
            try? await delivery.deliver(result, to: conversationId)
            return
        }

        // Route through the manager's gating chain. The manager auto-delivers the result
        // via whatever `ConnectionDelivering` it was constructed with — so long as the
        // host passed `self.delivery` as that value, the agent gets its reply.
        _ = await manager.handleInvocation(invocation, from: conversationId)
    }
}
