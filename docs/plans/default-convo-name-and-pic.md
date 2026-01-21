# Feature: Default Conversation Names and Profile Pictures

> **Status**: Draft
> **Author**: PRD Writer Agent
> **Created**: 2026-01-20
> **Updated**: 2026-01-20

## Overview

Replace generic "Untitled" placeholder text and blank gray circle avatars with intelligent, contextual defaults for conversation names and profile pictures. This creates a more polished, familiar experience by adopting industry-standard conventions for displaying group conversations.

## Problem Statement

Currently, conversations without custom names display "Untitled" and use blank gray circles as profile pictures. This creates several UX problems:

1. **Lack of context**: Users can't distinguish between multiple unnamed conversations at a glance
2. **Generic appearance**: The "Untitled" placeholder feels unfinished and unprofessional
3. **Anonymous confusion**: When multiple participants lack usernames (appearing as "Somebody"), conversations become indistinguishable
4. **Visual monotony**: All unnamed conversations look identical with gray circles

This is particularly problematic in Convos where users can participate in conversations anonymously without setting usernames or profile pictures.

## Goals

- [x] Provide contextual, meaningful names for all conversations without requiring user configuration
- [x] Create visually distinct profile pictures for every conversation, even when all participants are anonymous
- [x] Follow familiar industry patterns (like iMessage) for group conversation display
- [x] Ensure anonymous users can still distinguish between multiple conversations
- [x] Support both light and dark system themes with appropriate visual treatments

## Non-Goals

- Not implementing custom emoji selection (emojis are randomly assigned for anonymous groups)
- Not adding user-facing controls for managing auto-generated names or images
- Not changing how DM conversations are displayed (only affecting group conversations)
- Not modifying the underlying data model for conversation names/images (these remain optional)

## User Stories

### As a user with multiple unnamed group conversations, I want to see distinct names so that I can quickly identify which conversation is which

Acceptance criteria:
- [x] Conversations without custom names display participant usernames instead of "Untitled"
- [x] Names are formatted consistently (comma-separated, alphabetical order)
- [x] Two-person groups use "Name & Name" format (ampersand, not "and")
- [x] Solo conversations (only current user) display "New Convo"
- [x] Anonymous participants appear as "Somebodies" at the end (not individual "Somebody" entries)

### As a user in anonymous conversations, I want to see unique visual identifiers so that I can distinguish between multiple "Somebodies" conversations

Acceptance criteria:
- [x] Fully anonymous conversations (no participants with usernames) display "Somebodies" as the name
- [x] Each fully anonymous conversation gets a unique random emoji as its profile picture
- [x] The same conversation always shows the same emoji (deterministic based on conversation ID)
- [x] Emoji appears on a faint colored background matching the theme

### As a user viewing group conversations, I want to see familiar iMessage-style group avatars so that I can recognize conversations at a glance

Acceptance criteria:
- [x] Groups with one or more participants who have profile pictures show a clustered avatar layout
- [x] Current user's profile picture is excluded from the cluster (unless they're alone in the conversation)
- [x] Clustered avatars appear on a faint colored background
- [x] Background color adapts to system theme (light/dark mode)

### As a user viewing a mixed group with both named and anonymous participants, I want to see a meaningful name that acknowledges both types of members

Acceptance criteria:
- [x] Named participants appear first, alphabetically sorted
- [x] Anonymous participants appear at the end as "Somebodies" (plural)
- [x] Format follows Figma design: "Darick, Somebodies"

## Technical Design

### Architecture

This feature primarily affects:

- **ConvosCore**: Core logic for generating default names and selecting deterministic emojis
- **Main App**: View layer updates to `AvatarView`, `ConversationAvatarView`, and conversation display components
- **Existing Dependencies**:
  - `Conversation` model (already has optional `name` and `imageURL`)
  - `Profile.formattedNamesString` (needs updates for "Somebody" handling)
  - `AvatarView` and `MonogramView` (needs clustered avatar support)

**New Components Needed**:
- Emoji selection utility (deterministic random based on conversation ID)
- Clustered avatar view component (iMessage-style layout)
- Background color generator for avatar backgrounds (theme-aware)

### Data Model

No database changes required. The feature uses computed properties based on existing data:

**Existing fields (no changes)**:
```swift
public struct Conversation {
    public let name: String?           // Optional custom name
    public let imageURL: URL?          // Optional custom image
    public let members: [ConversationMember]
    // ...
}

public struct Profile {
    public let name: String?           // Optional username
    public let avatar: String?         // Optional avatar URL
    // ...
}
```

**New computed properties** (ConvosCore):
```swift
public extension Conversation {
    /// Returns the display name for the conversation.
    /// If a custom name is set, returns that. Otherwise, generates a contextual default.
    var computedDisplayName: String {
        // Logic for generating names based on members
    }

    /// Returns true if all members (excluding current user) have no username
    var isFullyAnonymous: Bool {
        // Check if all membersWithoutCurrent have nil names
    }

    /// Returns a deterministic emoji for this conversation
    /// Used when isFullyAnonymous is true and no custom image is set
    var defaultEmoji: String {
        // Deterministic selection based on conversation ID
    }
}

public extension Array where Element == Profile {
    /// Updated to handle "Somebody" sorting
    var formattedNamesString: String {
        // Named users first (alphabetically), then "Somebody" users at end
    }
}
```

### Display Logic

**Conversation Name Priority**:
1. If `conversation.name` exists and is not empty → use it
2. If DM conversation → use `otherMember.profile.displayName`
3. If group conversation → use `computedDisplayName`:
   - Solo (only current user) → "New Convo"
   - All others anonymous → "Somebodies"
   - Mixed or all named → formatted member names

**Profile Picture Priority**:
1. If `conversation.imageURL` exists → use it
2. If fully anonymous group → show random emoji on themed background
3. If group with profile pictures → show clustered iMessage-style avatar
4. Fallback → monogram or gray circle

### UI/UX

**Screens Affected**:
- Conversations List (`ConversationsListItem`)
- Conversation Detail Header (`ConversationView`, `MessagesView`)
- Pinned Conversations (`PinnedConversationItem`)

**New Views Needed**:
- `ClusteredAvatarView`: iMessage-style multi-person avatar layout
- `EmojiAvatarView`: Single emoji on themed background
- Background color utilities for theme-aware colored circles

**Navigation Flow**:
No navigation changes. Visual updates only.

**Design References**:
Figma: [Sample treatments](https://www.figma.com/design/p6mt4tEDltI4mypD3TIgUk/Convos-app?node-id=17347-41315)

**Avatar Specifications** (from Figma):
- Container: 56×56px, corner radius 32px (`--space/xl`)
- Background: `#f5f5f5` (`--color/fill/minimal`)
- Border: 1px solid `rgba(0,0,0,0.04)` (`--color/border/edge`)

**Emoji Avatar** (for anonymous groups):
- Emoji centered on gray background
- Font: SF Pro Rounded Semibold, 24px
- Sample emojis shown: 🥫, 🦺, 🌵, 😳

**Clustered Avatar Layout** (iMessage-style, 3 members):
- Main avatar (top-left): 25.2px diameter at position (8.5, 7)
- Bottom-left avatar: 16.8px diameter at position (16.9, 35)
- Bottom-right avatar: 16.8px diameter at position (35.1, 22.4)
- Each sub-avatar has 1px border with same edge color
- Border radius matches diameter (33.6px for main, 22.4px for small)

## Implementation Plan

### Phase 1: Name Generation Logic (ConvosCore)
- [x] Update `Profile.formattedNamesString` to sort named users first, anonymous users last
- [x] Add `Conversation.computedDisplayName` computed property
- [x] Add `Conversation.isFullyAnonymous` computed property
- [x] Handle edge cases: solo conversations, all-anonymous, mixed groups
- [x] Unit tests for all name formatting scenarios

### Phase 2: Emoji Selection (ConvosCore)
- [x] Create deterministic emoji selection utility
- [x] Add `Conversation.defaultEmoji` computed property
- [x] Define emoji set (exclude inappropriate emojis)
- [x] Ensure same conversation always gets same emoji (hash conversation ID)
- [x] Unit tests for emoji consistency

### Phase 3: Avatar View Updates (Main App)
- [x] Create `ClusteredAvatarView` for iMessage-style group avatars
- [x] Create `EmojiAvatarView` for anonymous group avatars
- [x] Add theme-aware background colors
- [x] Update `ConversationAvatarView` to choose appropriate avatar type
- [x] Exclude current user from clustered avatars (unless solo)
- [x] SwiftUI previews for all new components

### Phase 4: Integration and Polish
- [x] Update `ConversationsListItem` to use new computed names
- [x] Update conversation detail views to use new avatars
- [x] Test in light and dark mode
- [x] Test with various member configurations (solo, 2-person, multi-person, all-anonymous, mixed)
- [x] Accessibility testing (VoiceOver should read meaningful names)

## Testing Strategy

**Unit tests for** (ConvosCore):
- `Profile.formattedNamesString` with various member combinations
- `Conversation.computedDisplayName` edge cases:
  - Solo conversation (only current user)
  - Two named users
  - Multiple named users
  - All anonymous users
  - Mixed named and anonymous users
  - Empty member list
- `Conversation.defaultEmoji` consistency (same ID = same emoji)

**Integration tests for**:
- Avatar view selection logic (when to show clustered vs emoji vs monogram)
- Theme switching (background colors update correctly)
- Conversation list rendering with new defaults

**Manual testing scenarios**:
1. Create conversation with no custom name/image → verify computed name appears
2. Create multiple all-anonymous conversations → verify unique emojis
3. Add/remove members → verify name updates correctly
4. Toggle light/dark mode → verify backgrounds adapt
5. Set custom name/image → verify overrides still work
6. Solo conversation → verify shows "New Convo"
7. Two-person group → verify "Name and Name" format
8. DM conversation → verify unchanged behavior

## Edge Cases and Considerations

### Name Formatting Edge Cases

| Scenario | Expected Display Name | Notes |
|----------|----------------------|-------|
| Solo (only current user) | "New Convo" | Indicates pending invites |
| Two named users | "Phil & Eric" | Uses "&" not "and" (per Figma) |
| Three+ named users | "Quarterrible, McGuyen, Moutsopolous" | Alphabetical, comma-separated |
| All anonymous (2+ users) | "Somebodies" | Plural form |
| Single anonymous | "Somebody" | Singular form |
| Mixed: 1 named + anonymous | "Darick, Somebodies" | Named first, then "Somebodies" |
| One named user (current user only has joined) | "Darick" | Other member's name |
| Empty members list | "Untitled" | Fallback for edge case |

### Avatar Edge Cases

| Scenario | Expected Avatar | Notes |
|----------|----------------|-------|
| Custom image set | Use custom image | Always highest priority |
| All anonymous, no pics | Random emoji | Deterministic based on ID |
| Solo with profile pic | Show own pic | Exception to exclusion rule |
| Solo without profile pic | Monogram or placeholder | Existing behavior |
| Mixed pics and no-pics | Clustered (pics only) | Show available pics |
| All members have pics | Clustered (exclude current) | Standard iMessage style |
| DM with other's pic | Show other's pic | Existing DM behavior |

### Anonymous User Sorting

**Rule**: Named users alphabetically first, then "Somebodies" (plural) if any anonymous users exist.

Examples (from Figma):
- `["Darick", "Somebody", "Somebody"]` → "Darick, Somebodies"
- `["Somebody", "Somebody"]` → "Somebodies"
- `["Somebody"]` → "Somebody"
- `["Phil", "Eric"]` → "Phil & Eric"
- `["Quarterrible", "McGuyen", "Moutsopolous"]` → "Quarterrible, McGuyen, Moutsopolous"

**Rationale**: Using "Somebodies" (plural) instead of listing individual "Somebody" entries is cleaner and avoids repetitive "Somebody, Somebody, Somebody" patterns. Named users come first for specificity.

### Theme Adaptation

**Background colors must**:
- Use semantic color names (e.g., `.colorBackgroundGroupAvatar`)
- Adapt automatically to light/dark mode
- Provide sufficient contrast for overlaid emojis/images
- Match existing design system colors where possible

### Performance Considerations

- Emoji selection should be O(1) using hashing, not iterating through possibilities
- Clustered avatar layout should efficiently handle 1-6 profile pictures (rare to have more visible)
- Computed names should be lightweight (simple string concatenation)
- Consider caching computed values if performance issues arise during scrolling

### Localization

[NEEDS DECISION] How should the following strings be localized?
- "New Convo"
- "Somebody" (singular)
- "Somebodies" (plural)
- Name separator formatting (", and" pattern)

Should emoji selection be locale-aware (avoid culturally inappropriate emojis in certain regions)?

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Users confused by auto-generated names | Medium | Maintain ability to set custom names; auto-generated names are clearly derived from member list |
| Emoji randomness creates unexpected results | Low | Carefully curate emoji list to exclude ambiguous/offensive options; deterministic selection ensures consistency |
| Clustered avatars difficult to read at small sizes | Medium | Follow iMessage sizing conventions; test at smallest list item size; ensure sufficient contrast |
| Performance impact on conversations list scrolling | Low | Use lightweight computed properties; consider caching if needed |
| Dark mode backgrounds don't provide enough contrast | Medium | Test thoroughly in both themes; use design system colors with proven accessibility |
| Name updates don't reflect member changes | High | Ensure computed properties are reactive; test add/remove member flows |

## Open Questions

- [x] What is the exact Figma reference for the clustered avatar layout? (Use Figma MCP)
- [x] Should "New Convo" be localized? What's the localization strategy?
- [x] How many emojis should be in the random pool? (Suggest 50-100)
- [x] Should clustered avatars show a maximum number of faces (e.g., max 4) with "+N" indicator?
- [x] What happens to computed names when custom name is removed? (Revert to computed)
- [x] Should we animate the transition from "New Convo" to member-based name when first member joins?
- [x] Do we need analytics events to track how often auto-generated names are used vs custom names?

## References

- Existing: `ConvosCore/Sources/ConvosCore/Storage/Models/Conversation.swift`
- Existing: `ConvosCore/Sources/ConvosCore/Storage/Models/Profile.swift`
- Existing: `Convos/Shared Views/AvatarView.swift`
- Existing: `Convos/Shared Views/MonogramView.swift`
- ADR: [005-profile-storage-in-conversation-metadata.md](/Users/courter/Code/convos-ios-default-convo-name-and-pic/docs/adr/005-profile-storage-in-conversation-metadata.md)
- Design: [Figma - Sample treatments](https://www.figma.com/design/p6mt4tEDltI4mypD3TIgUk/Convos-app?node-id=17347-41315)
- Similar feature: iMessage group conversation display

## Follow-up Items

After implementation, consider:
1. **Analytics**: Track adoption of custom names vs auto-generated names
2. **User feedback**: Survey users on clarity of auto-generated names
3. **Design iteration**: Refine clustered avatar layout based on usage data
4. **Accessibility audit**: Ensure VoiceOver reads meaningful information
5. **Emoji expansion**: Consider allowing user-selected emojis for anonymous groups (future)
6. **Custom backgrounds**: Explore user-selected background colors for avatars (future)
