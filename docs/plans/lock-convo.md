# Lock Convo Feature - Implementation Plan

## Status

Draft

## Overview

The "lock convo" feature allows super admins to lock a conversation, which:
1. Prevents new members from joining (sets `addMemberPolicy` to `deny`)
2. Rotates the invite tag to invalidate existing invites
3. Hides the share button from users who cannot add members

## Architecture Summary

The implementation touches three main areas:
1. **ConvosCore** - Permission management and invite tag rotation logic
2. **ConversationViewModel** - Expose permission state to the UI
3. **Views** - Conditional UI rendering based on permissions

---

## Phase 1: Core Logic (ConvosCore)

### Step 1: Extend ConversationMetadataWriterProtocol for Lock/Unlock

**File:** `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift`

Add two new methods to the protocol:

```swift
func lockConversation(for conversationId: String) async throws
func unlockConversation(for conversationId: String) async throws
```

**Implementation details for `lockConversation`:**
1. Get the XMTP group via `inboxStateManager.waitForInboxReadyResult().client`
2. Rotate the invite tag by calling `rotateInviteTag()` on the group (see Step 2)
3. Call `group.updateAddMemberPermission(newPermissionOption: .deny)` to prevent all member additions
4. Regenerate invites for the creator with the new tag

**Implementation details for `unlockConversation`:**
1. Get the XMTP group
2. Call `group.updateAddMemberPermission(newPermissionOption: .allow)` to restore member additions
3. No invite tag rotation needed (existing invites remain invalid from the lock)

---

### Step 2: Add Invite Tag Rotation to XMTPGroup+CustomMetadata

**File:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`

Add a new public method:

```swift
public func rotateInviteTag() async throws {
    var customMetadata = try currentCustomMetadata
    customMetadata.tag = try generateSecureRandomString(length: 10)
    try await updateMetadata(customMetadata)
}
```

This replaces the existing tag with a new random string, invalidating all previously generated invites that reference the old tag.

---

### Step 3: Add isLocked Property to Database Model

**File:** `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift`

Add `isLocked` as a persisted column:

```swift
// Add to Columns enum
static let isLocked: Column = Column(CodingKeys.isLocked)

// Add to struct properties
let isLocked: Bool
```

**Why store in DB instead of querying XMTP on-demand:**
- GRDB observation automatically notifies UI of changes
- Updated during conversation sync from XMTP
- Consistent with how other conversation properties are handled
- No need for separate async loading in ViewModel

**Sync implementation:**
When syncing conversations from XMTP, check `group.permissionPolicySet().addMemberPolicy == .deny` and persist to `isLocked` column.

**Migration:**
Add a database migration to add the `isLocked` column with default value `false`.

**Also update:**
- `ConvosCore/Sources/ConvosCore/Storage/Models/Conversation.swift` - Add `isLocked` property
- All `with(...)` builder methods in DBConversation to include `isLocked`

---

### Step 4: Update InviteWriter to Support Tag Rotation

**File:** `ConvosCore/Sources/ConvosCore/Storage/Writers/InviteWriter.swift`

When the invite tag is rotated, the local invite in the database becomes stale. Add a method to regenerate invites after tag rotation:

```swift
func regenerateInvite(for conversationId: String) async throws -> Invite
```

This will:
1. Delete existing invites for this conversation
2. Fetch the conversation with the new tag
3. Generate new invite with updated tag

---

### Step 5: Add Mock Implementations

**File:** `ConvosCore/Sources/ConvosCore/Mocks/MockConversationMetadataWriter.swift`

Add mock implementations for `lockConversation` and `unlockConversation`.

---

## Phase 2: ViewModel Integration

### Step 6: Extend ConversationViewModel for Lock/Unlock

**File:** `Convos/Conversation Detail/ConversationViewModel.swift`

Add the following:

**Computed properties:**
```swift
var isCurrentUserSuperAdmin: Bool {
    conversation.members.first(where: { $0.isCurrentUser })?.role == .superAdmin
}

var canToggleLock: Bool {
    isCurrentUserSuperAdmin
}

var isLocked: Bool {
    conversation.isLocked  // From GRDB observation
}

var canAddMembers: Bool {
    !isLocked  // If locked, no one can add members
}
```

**Methods:**
```swift
func toggleLock() async  // Calls lock/unlock on ConversationMetadataWriter
```

**Note:** No need for `isLoadingLockState` or `loadLockState()` since `isLocked` comes from GRDB observation through the `Conversation` model. The UI automatically updates when the database changes.

---

## Phase 3: UI Updates

### Step 7: Update ConversationInfoView for Lock Toggle

**File:** `Convos/Conversation Detail/ConversationInfoView.swift`

Current code (lines 163-167) shows a disabled placeholder. Replace with:

- Show toggle only to super admins (`canToggleLock`)
- Non-admins see read-only "Membership: Locked/Open" status (toggle is disabled)
- Conditionally show share link based on `canAddMembers`

**Lock Toggle Behavior (Super Admin Only):**

When a super admin toggles the lock ON, show a confirmation using `InfoView`:
- **Title:** "Lock this convo?"
- **Description:** "No one new will be able to join and existing convo codes will be invalidated."
- **Buttons:**
  - "Cancel" - dismisses the sheet, convo stays unlocked
  - "Lock convo" - confirms and locks the conversation

This confirmation prevents accidental locking and makes the consequences clear.

---

### Step 8: Update Toolbar Icon When Locked

**File:** `Convos/Conversation Detail/ConversationView.swift`

When the conversation is locked, the share button in the toolbar should change:

**Current behavior:** Share icon (`square.and.arrow.up`) → presents share view

**New behavior when locked:**
- Icon changes to lock icon (SF Symbol: `lock.fill`)
- When tapped, presents an `InfoView` as a sheet explaining the locked state

**InfoView Content:**
- **Title:** "This convo is locked"
- **Description:** "Nobody new can join this convo.\n\nNew convo codes can't be created, and any outstanding codes no longer work."
- **Buttons (role-based):**
  - **Admin (non-superAdmin):** Single "Got it" button that dismisses
  - **Super Admin:** Two buttons:
    - "Got it" - dismisses the sheet
    - "Manage" (secondary style) - dismisses and presents `ConversationInfoView`

**Implementation notes:**
- Add `@State private var presentingLockedInfo: Bool = false` to track info sheet
- Add `@State private var presentingInfoAfterLockedDismiss: Bool = false` for the "Manage" flow
- Update the toolbar switch to handle the locked state:

```swift
case .share:
    if viewModel.isLocked {
        Button {
            presentingLockedInfo = true
        } label: {
            Image(systemName: "lock.fill")
                .foregroundStyle(.colorTextPrimary)
        }
        .sheet(isPresented: $presentingLockedInfo) {
            LockedConvoInfoView(
                canManage: viewModel.isCurrentUserSuperAdmin,
                onManage: {
                    presentingLockedInfo = false
                    presentingInfoAfterLockedDismiss = true
                }
            )
        }
        .sheet(isPresented: $presentingInfoAfterLockedDismiss) {
            ConversationInfoView(viewModel: viewModel, focusCoordinator: focusCoordinator)
        }
    } else {
        // existing share button code
    }
```

---

### Step 9: Create LockedConvoInfoView

**File:** `Convos/Conversation Detail/LockedConvoInfoView.swift` (new file)

A specialized `InfoView` variant for displaying locked convo information:

```swift
struct LockedConvoInfoView: View {
    let canManage: Bool
    var onManage: (() -> Void)?

    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("This convo is locked")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("Nobody new can join this convo.\n\nNew convo codes can't be created, and any outstanding codes no longer work.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                if canManage {
                    Button {
                        onManage?()
                    } label: {
                        Text("Manage")
                    }
                    .convosButtonStyle(.secondary(fullWidth: true))
                }
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}
```

---

### Step 10: Create LockConvoConfirmationView

**File:** `Convos/Conversation Detail/LockConvoConfirmationView.swift` (new file)

Confirmation view shown when super admin attempts to lock a convo:

```swift
struct LockConvoConfirmationView: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Lock this convo?")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("No one new will be able to join and existing convo codes will be invalidated.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    onConfirm()
                } label: {
                    Text("Lock convo")
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                .convosButtonStyle(.secondary(fullWidth: true))
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}
```

---

### Step 11: Update MessagesListView for Locked Convos

**File:** `Convos/Conversation Detail/Messages/MessagesListView/MessagesListView.swift`

Current logic (lines 21-28) shows the invite view if the user is the creator. Update this to also consider the locked state:

**Current:**
```swift
if conversation.creator.isCurrentUser {
    InviteView(invite: invite)
} else {
    ConversationInfoPreview(conversation: conversation)
}
```

**New:**
```swift
if conversation.creator.isCurrentUser && !conversation.isLocked {
    InviteView(invite: invite)
} else {
    ConversationInfoPreview(conversation: conversation)
}
```

**Rationale:** When a convo is locked, the invite is no longer valid and cannot be shared. Showing it would be misleading. Instead, show the conversation info preview, which is more appropriate for a locked state. This applies even to the super admin who locked it.

---

## Key Considerations

1. **XMTP SDK Capability**: Verify that `PermissionOption.deny` is available in the XMTP SDK. If not, use `PermissionOption.superAdmin` as an alternative.

2. **Sync Considerations**: When a conversation is locked by another super admin, the UI should reflect this. Consider listening for permission change events from XMTP.

3. **Race Conditions**: If multiple super admins try to toggle the lock simultaneously, the last write wins. This is acceptable for MVP.

4. **Invite Regeneration**: When unlocking, existing invites remain invalid. Users need to share new invites.

---

## Critical Files Summary

| File | Changes |
|------|---------|
| `ConvosCore/.../DBConversation.swift` | Add `isLocked` column + migration |
| `ConvosCore/.../Conversation.swift` | Add `isLocked` property |
| `ConvosCore/.../ConversationMetadataWriter.swift` | Add lock/unlock methods |
| `ConvosCore/.../XMTPGroup+CustomMetadata.swift` | Add `rotateInviteTag()` |
| `ConvosCore/.../InviteWriter.swift` | Add `regenerateInvite()` |
| `Convos/.../ConversationViewModel.swift` | Expose `isLocked`, `isCurrentUserSuperAdmin`, `canToggleLock` to UI |
| `Convos/.../ConversationView.swift` | Lock icon in toolbar when locked, info sheet presentation |
| `Convos/.../ConversationInfoView.swift` | Lock toggle (super admin only), confirmation on lock |
| `Convos/.../LockedConvoInfoView.swift` | **New** - Info view explaining locked state with role-based buttons |
| `Convos/.../LockConvoConfirmationView.swift` | **New** - Confirmation dialog before locking |
| `Convos/.../MessagesListView.swift` | Hide invite, show convo info when locked |

---

## Unit Tests

Add tests in `ConvosCore/Tests/ConvosCoreTests/`:

1. **LockConversationTests.swift** - Test lock/unlock logic
2. **InviteTagRotationTests.swift** - Test that tag rotation invalidates old invites
3. **PermissionCheckTests.swift** - Test `canAddMembers` and `canToggleLock` logic

---

## Future Enhancements

These features are not in scope for the initial implementation but should leverage the lock convo infrastructure:

### Auto-Lock on Single-Use Invite Completion

The invite system supports "single use invites." When an inviter completes a join request for a single-use invite, the convo should automatically lock, preventing anyone else from joining.

**Implementation notes:**
- Trigger lock after successful `completeJoinRequest` for single-use invites
- No confirmation dialog needed (user opted into this behavior when creating the invite)
- UI should indicate the convo was auto-locked due to single-use invite fulfillment

### Auto-Lock at Max Capacity (150 Members)

Convos has a hard limit of 150 members per group. When max capacity is reached, the group should automatically enter the locked state.

**Implementation notes:**
- Check member count after successful member addition
- If count reaches 150, trigger lock automatically
- UI should indicate the convo is locked due to capacity
- Consider showing remaining capacity in ConversationInfoView (e.g., "142/150 members")

---

## Related ADRs

- ADR 001: Decentralized Invite System with Cryptographic Tokens
- ADR 002: Per-Conversation Identity Model
