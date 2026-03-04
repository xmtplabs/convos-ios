# ConversationsView UICollectionView Migration

## Goal
Replace the SwiftUI `List`-based implementation of `ConversationsView` with a UICollectionView to improve scroll performance while keeping SwiftUI cells.

## Current Architecture

```
ConversationsView (SwiftUI)
├── PinnedConversationsSection (SwiftUI)
│   ├── PinnedConversationItem (SwiftUI) × N
├── List
│   ├── ConversationsListItem (SwiftUI) × N
│       └── swipeActions (SwiftUI)
│       └── contextMenu (SwiftUI)
```

**Problems:**
- Scroll performance issues with large lists
- Pinned section has unwanted parallax/scale/opacity effects on scroll
- SwiftUI List has limited control over scroll behavior

## Target Architecture

```
ConversationsView (SwiftUI)
└── ConversationsViewRepresentable (UIViewControllerRepresentable)
    └── ConversationsViewController (UIViewController)
        └── UICollectionView
            ├── Section 0: Pinned (CompositionalLayout - adaptive grid)
            │   └── PinnedConversationCell (UIHostingConfiguration)
            ├── Section 1: List (CompositionalLayout - list)
            │   └── ConversationListItemCell (UIHostingConfiguration)
            │       └── leadingSwipeActions (UISwipeActionsConfiguration)
            │       └── trailingSwipeActions (UISwipeActionsConfiguration)
            │       └── contextMenu (UIContextMenuConfiguration)
```

## Implementation Plan

### Phase 1: Core Infrastructure

**1.1 Create ConversationsViewController**
- `Convos/Conversations List/View Controller/ConversationsViewController.swift`
- Similar pattern to `MessagesViewController`
- Properties:
  - `collectionView: UICollectionView`
  - `dataSource: ConversationsDataSource`
  - `state: ConversationsState` (conversations, pinned/unpinned, filter)
- Delegate callbacks for actions

**1.2 Create ConversationsDataSource**
- `Convos/Conversations List/View Controller/ConversationsDataSource.swift`
- `UICollectionViewDiffableDataSource` with sections:
  - `.pinned` - pinned conversations
  - `.list` - unpinned conversations
  - `.empty` - empty state CTA (when no conversations)
  - `.filteredEmpty` - filtered empty state

**1.3 Create Compositional Layout**
- `Convos/Conversations List/View Controller/ConversationsCollectionLayout.swift`
- Section 0 (Pinned): Adaptive grid
  - 1 item: centered, full width
  - 2 items: side-by-side
  - 3+ items: 3-column grid with multiple rows
- Section 1 (List): Full-width list items

### Phase 2: Cells

**2.1 PinnedConversationCell**
- `Convos/Conversations List/View Controller/Cells/PinnedConversationCell.swift`
- Uses `UIHostingConfiguration` to embed existing `PinnedConversationItem` SwiftUI view
- Self-sizing with `preferredLayoutAttributesFitting`

**2.2 ConversationListItemCell**
- `Convos/Conversations List/View Controller/Cells/ConversationListItemCell.swift`
- Uses `UIHostingConfiguration` to embed existing `ConversationsListItem` SwiftUI view
- Self-sizing with `preferredLayoutAttributesFitting`

**2.3 EmptyStateCell**
- For empty CTA and filtered empty states
- Embeds existing SwiftUI views

### Phase 3: Interactions

**3.1 Swipe Actions**
```swift
func collectionView(_ collectionView: UICollectionView, 
                    leadingSwipeActionsConfigurationForItemAt indexPath: IndexPath) 
    -> UISwipeActionsConfiguration?

func collectionView(_ collectionView: UICollectionView, 
                    trailingSwipeActionsConfigurationForItemAt indexPath: IndexPath) 
    -> UISwipeActionsConfiguration?
```

Leading actions:
- Delete (red, trash icon)
- Explode (black, burst icon) - only for creators of non-pending conversations

Trailing actions:
- Mark as read/unread (black, message icon)
- Mute/Unmute (purple, bell icon)

**3.2 Context Menus**
```swift
func collectionView(_ collectionView: UICollectionView,
                    contextMenuConfigurationForItemAt indexPath: IndexPath,
                    point: CGPoint) -> UIContextMenuConfiguration?
```

Reuse existing `ConversationContextMenuContent` logic to build `UIMenu`.

**3.3 Selection**
- Tap to select conversation
- Track `selectedConversationId` 
- Visual highlight for selected cell

### Phase 4: SwiftUI Bridge

**4.1 ConversationsViewRepresentable**
- `Convos/Conversations List/View Controller/ConversationsViewRepresentable.swift`
- `UIViewControllerRepresentable` wrapper
- Bindings:
  - `conversations: [Conversation]`
  - `pinnedConversations: [Conversation]`
  - `unpinnedConversations: [Conversation]`
  - `selectedConversationId: Binding<String?>`
  - `activeFilter: ConversationFilter`
- Callbacks:
  - `onSelectConversation: (Conversation) -> Void`
  - `onDeleteConversation: (Conversation) -> Void`
  - `onExplodeConversation: (Conversation) -> Void`
  - `onToggleMute: (Conversation) -> Void`
  - `onToggleReadState: (Conversation) -> Void`
  - `onTogglePin: (Conversation) -> Void`

**4.2 Update ConversationsView**
Replace `conversationsList` with `ConversationsViewRepresentable` while keeping:
- Toolbar items
- Sheet presentations
- Navigation structure

### Phase 5: Polish & Testing

**5.1 Animations**
- Smooth insert/delete animations via DiffableDataSource
- Pin/unpin transitions between sections

**5.2 Accessibility**
- Preserve all accessibility identifiers
- Swipe action accessibility labels
- VoiceOver support

**5.3 QA Verification**
- Run baseline test `qa/tests/25-conversations-list-baseline.md`
- Compare screenshots with baseline

## File Structure

```
Convos/Conversations List/
├── ConversationsView.swift (updated - uses representable)
├── ConversationsViewModel.swift (unchanged)
├── ConversationsListItem.swift (unchanged - reused in cells)
├── PinnedConversationsSection.swift (keep for reference, may remove later)
├── ConversationContextMenuContent.swift (unchanged - reused)
├── View Controller/
│   ├── ConversationsViewController.swift
│   ├── ConversationsDataSource.swift
│   ├── ConversationsCollectionLayout.swift
│   ├── ConversationsViewRepresentable.swift
│   └── Cells/
│       ├── PinnedConversationCell.swift
│       ├── ConversationListItemCell.swift
│       └── EmptyStateCell.swift
```

## Key Differences from MessagesViewController

| Aspect | MessagesViewController | ConversationsViewController |
|--------|----------------------|---------------------------|
| Layout | Custom MessagesCollectionLayout | CompositionalLayout |
| Data Source | Manual UICollectionViewDataSource | DiffableDataSource |
| Sections | Single section | Multiple sections (pinned/list) |
| Swipe Actions | None | Full swipe actions |
| Selection | None | Selection tracking |
| Keyboard | Complex keyboard handling | No keyboard handling |

## Dependencies

- DifferenceKit (already used for messages) - for efficient diffing
- Existing SwiftUI views (ConversationsListItem, PinnedConversationItem, etc.)

## Migration Strategy

1. Build new implementation alongside existing
2. Feature flag or A/B test
3. Verify with QA baseline test
4. Remove old implementation once verified

## Success Criteria

- [ ] All baseline screenshots match (feature parity)
- [ ] Smooth 60fps scrolling with 100+ conversations
- [ ] Pinned section scrolls naturally (no parallax)
- [ ] Swipe actions work correctly
- [ ] Context menus work correctly
- [ ] Selection highlighting works
- [ ] Empty states display correctly
- [ ] Filter behavior works correctly
