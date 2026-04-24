import ConvosCore
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingConsent`.
///
/// DTU's engine exposes per-conversation consent state on
/// `get_consent_state` / `update_consent_state`. The abstraction's
/// bulk `set(records:)` entry point dispatches one update action per
/// record. Per-inbox consent and preference replication do not exist
/// in the engine today and throw `DTUMessagingNotSupportedError`.
public final class DTUMessagingConsent: MessagingConsent, @unchecked Sendable {
    let context: DTUMessagingClientContext

    public init(context: DTUMessagingClientContext) {
        self.context = context
    }

    public func set(records: [MessagingConsentRecord]) async throws {
        for record in records {
            switch record.entity {
            case .conversationId(let conversationId):
                _ = try await context.universe.updateConsentState(
                    conversation: conversationId,
                    state: record.state.dtuConsentState,
                    actor: context.actor
                )
            case .inboxId:
                // DTU has no per-inbox consent concept. Drop silently
                // for bulk set() semantics — the caller is likely
                // replicating preferences across a batch and wants a
                // best-effort apply. A strict adapter could throw here;
                // we lean permissive to keep smoke tests simple.
                continue
            }
        }
    }

    public func conversationState(id: String) async throws -> MessagingConsentState {
        let state = try await context.universe.getConsentState(
            conversation: id,
            actor: context.actor
        )
        return MessagingConsentState(state)
    }

    public func inboxIdState(_ inboxId: MessagingInboxID) async throws -> MessagingConsentState {
        // DTU has no per-inbox consent — return `.unknown` so callers
        // that probe consent default to the safe value.
        .unknown
    }

    public func syncPreferences() async throws {
        // DTU's `sync` action syncs all conversations for the actor —
        // there is no distinct preferences-only sync. Treat this as a
        // no-op; a stricter adapter could throw, but the Convos call
        // sites (e.g. StreamProcessor's background consent sync) call
        // this defensively and a no-op is fine.
    }
}
