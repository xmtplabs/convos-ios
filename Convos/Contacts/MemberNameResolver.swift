import ConvosCore
import Foundation

/// Stopgap for the window between "we invite a contact" and "their per-
/// conversation profile snapshot arrives." When an in-group render site
/// would emit "Somebody" because the per-conversation profile name is
/// empty, the resolver consults the contacts list and returns a stored
/// contact name if one exists. See PRD §Phase 2.9.
///
/// Read-only — looking up a contact for rendering does not auto-add or
/// modify any contact rows. Per-conversation profile name always wins;
/// this resolver is only consulted at render sites when the profile name
/// is missing.
struct MemberNameResolver {
    private let contactsRepository: any ContactsRepositoryProtocol

    init(contactsRepository: any ContactsRepositoryProtocol) {
        self.contactsRepository = contactsRepository
    }

    /// Returns the contact's stored display name for the given inbox, or
    /// `nil` if the inbox is not a known contact or the contact has no
    /// stored name. Callers compose this with the existing per-conversation
    /// profile name and the "Somebody" sentinel:
    ///
    ///   profile.name (if non-empty) → contactName(inboxId) → "Somebody"
    ///
    /// The full resolution is implemented inside `ConversationUpdate.summary
    /// (memberNameOverride:)` and the matching `formattedNamesString` overloads
    /// — callers pass `resolver.contactName(for:)` as the override and the
    /// existing precedence logic stays in ConvosCore.
    func contactName(for inboxId: String) -> String? {
        guard let contact = try? contactsRepository.fetchContact(inboxId: inboxId) else {
            return nil
        }
        guard let stored = contact.displayName, !stored.isEmpty else {
            return nil
        }
        return stored
    }
}
