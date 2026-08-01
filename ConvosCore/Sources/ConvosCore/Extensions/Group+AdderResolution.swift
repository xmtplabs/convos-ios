import Foundation
@preconcurrency import XMTPiOS

/// Outcome of looking up who added the local user to a group.
///
/// `.none` and `.unresolved` are deliberately distinct: "nobody added us" is a
/// fact we can act on, while "the lookup failed" means we know nothing.
/// Collapsing them lets a failed read pass as a self-created group, which would
/// let a blocked inviter's welcome through on the creator's contact status
/// alone.
enum AdderResolution: Equatable {
    /// The adder is known.
    case known(String)
    /// There is genuinely no adder - a group the local user created.
    case none
    /// The lookup itself failed. We don't know who invited us.
    case unresolved

    /// The adder when we actually resolved one, else nil. Callers that only
    /// need "who do I record" (as opposed to "may I trust this") use this;
    /// `.none` and `.unresolved` both mean there is nothing to persist.
    var knownInboxId: String? {
        switch self {
        case let .known(inboxId): return inboxId
        case .none, .unresolved: return nil
        }
    }
}

extension XMTPiOS.Group {
    /// Who added the local user to this group.
    ///
    /// `addedByInboxId()` is a local libxmtp read of a NOT NULL column
    /// (`added_by_inbox_id`), so an empty string is the genuine "no adder"
    /// signal and it throws only when the lookup fails (a storage error, or the
    /// group row is missing). Never rethrows - a failed read must not sink an
    /// inbound welcome - but the failure is surfaced as `.unresolved` rather
    /// than silently flattened, so trust decisions can fail closed.
    ///
    /// Single definition on purpose. Both the consent gate
    /// (`StreamProcessor.contactsVouch`) and the persistence path
    /// (`ConversationWriter.createDBConversation`) resolve the adder, and these
    /// empty-vs-throw semantics are subtle enough that two copies would drift.
    func resolvedAdder() -> AdderResolution {
        do {
            let addedByInboxId = try addedByInboxId()
            return addedByInboxId.isEmpty ? .none : .known(addedByInboxId)
        } catch {
            Log.warning(
                "addedByInboxId failed for \(id); treating adder as unresolved: \(error.localizedDescription)"
            )
            return .unresolved
        }
    }
}
