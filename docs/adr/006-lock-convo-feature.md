# ADR 006: Lock Convo Feature

> **Status**: Accepted
> **Author**: Claude (AI Assistant)
> **Created**: 2026-01-15

## Context

Convos allows users to create and manage conversations with a decentralized invite system (ADR 001). However, there are scenarios where a super admin may want to prevent new members from joining:

- Private discussions that should remain within the current member set
- Sensitive conversations where the invite link may have been accidentally shared
- Situations where existing invites need to be invalidated immediately

Without a lock mechanism, once an invite is shared, there is no way to prevent someone with that invite from requesting to join.

## Decision

We implemented a "lock convo" feature that allows super admins to lock a conversation, which:

1. **Prevents new members from joining** by setting the XMTP `addMemberPolicy` to `.deny`
2. **Invalidates all existing invites** by rotating the invite tag
3. **Provides clear UI feedback** through lock icons and confirmation dialogs

### Key Architectural Decisions

#### 1. XMTP Permission Policy for Enforcement

We use XMTP's `updateAddMemberPermission(newPermissionOption: .deny)` to enforce the lock at the protocol level.

**Why**: XMTP's MLS (Message Layer Security) permission policies are enforced by all conforming clients. This provides cryptographic enforcement rather than relying on client-side checks that could be bypassed.

#### 2. Local Database Storage for Lock State

Store `isLocked` as a persisted column in `DBConversation` (GRDB), derived from XMTP's `addMemberPolicy` during sync.

**Why**:
- GRDB observation automatically notifies UI of changes without manual refresh
- Consistent with how other conversation properties are handled
- Eliminates the need for separate async loading in ViewModels
- The lock state is derived from `permissionPolicySet().addMemberPolicy == .deny`

#### 3. Invite Tag Rotation on Lock

When locking a convo, automatically rotate the invite tag before setting the permission policy.

**Why**:
- Rotating the invite tag cryptographically invalidates all previously generated invites (see ADR 001)
- Provides defense-in-depth beyond the permission policy
- The creator's local invite is regenerated with the new tag after locking

**Note**: When unlocking, we do NOT rotate the invite tag again. Old invites remain invalid, which is intentional. Users must share new invites after unlocking.

#### 4. Permission Model: Super Admin Only

Only users with the `superAdmin` role can lock or unlock a conversation.

**Why**:
- Locking is a significant action that affects all members' ability to invite others
- Consistent with other high-impact actions like removing members or exploding the convo

#### 5. UI Design

- **Toolbar**: Lock icon replaces share icon when locked; tapping shows info sheet
- **Confirmation**: Super admins see confirmation dialog before locking
- **Role-based actions**: Info sheet shows "Unlock" for super admins, "Got it" for others
- **Invite hiding**: Invite card is hidden when convo is locked

## Consequences

### Positive

- Cryptographic enforcement via XMTP permission policy
- Invite invalidation ensures old invites cannot be used
- Clear UI feedback through lock icons and dialogs
- Consistent sync across all members
- Reversible action (though old invites remain invalid)

### Negative

- Invite invalidation is permanent even after unlocking
- No partial lock (cannot allow some members to invite while blocking others)
- Brief sync delay before all members see updated state

## Implementation Notes

**Core files**:
- `ConvosCore/.../DBConversation.swift` - `isLocked` column
- `ConvosCore/.../ConversationMetadataWriter.swift` - Lock/unlock methods
- `ConvosCore/.../ConversationWriter.swift` - Sync logic deriving `isLocked`
- `ConvosCore/.../XMTPGroup+CustomMetadata.swift` - `rotateInviteTag()`

**UI files**:
- `Convos/.../ConversationViewModel.swift` - `isLocked`, `canToggleLock`, `toggleLock()`
- `Convos/.../ConversationView.swift` - Toolbar lock icon
- `Convos/.../ConversationInfoView.swift` - Lock toggle in settings
- `Convos/.../LockedConvoInfoView.swift` - Info sheet for locked state
- `Convos/.../LockConvoConfirmationView.swift` - Confirmation before locking

**Tests**:
- `ConvosCore/Tests/ConvosCoreTests/LockConversationTests.swift`

## Related Decisions

- [ADR 001](./001-invite-system-architecture.md): Decentralized Invite System (invite tag rotation mechanism)
- [ADR 002](./002-per-conversation-identity-model.md): Per-Conversation Identity Model (super admin role context)
- [PRD](../plans/lock-convo.md): Lock Convo Implementation Plan
