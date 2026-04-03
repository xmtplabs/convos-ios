# App Icon Badge Count

> **Branch**: `jarod/app-icon-badge-count`

## Goal

Show the number of unread conversations as a badge on the app icon. Clear the badge when the user opens the app.

## Current state

- `ConversationLocalState.isUnread` tracks per-conversation unread state in GRDB
- Incoming messages from other participants set `isUnread = true` via `ConversationWriter.fetchAndStoreLatestMessages` and `IncomingMessageWriter`
- The user can manually mark read/unread via swipe actions and context menus
- The Notification Service Extension (NSE) processes push notifications but does not set badge counts
- No badge management exists anywhere in the codebase today

## Design

### Badge = count of unread conversations

The badge number represents the count of conversations where `isUnread == true`. This is consistent with how other messaging apps work (iMessage, WhatsApp) — the badge reflects conversations with new messages, not total unread messages.

### Three touch points

1. **NSE increments the badge** when delivering a notification for a new message
2. **App clears the badge to zero** when foregrounded
3. **App updates the badge** when the unread count changes while running (marking read/unread, new messages arriving)

### NSE badge increment

The NSE already processes push notifications and has access to the shared GRDB database. When it delivers a notification:

1. Query the unread conversation count from GRDB
2. Set `content.badge` on the `UNMutableNotificationContent` to that count

This is cheap (single SQL count query) and ensures the badge stays accurate even when multiple notifications arrive while the app is backgrounded.

The NSE already marks conversations as unread when storing incoming messages, so the count query will reflect the correct state.

**Wait — does the NSE mark conversations unread?** Let me check. The NSE calls `pushHandler.handlePushNotification` which decrypts and stores the message. The `IncomingMessageWriter` stores messages but the unread flag is set by `ConversationWriter.fetchAndStoreLatestMessages` which runs in the main app's sync flow, not the NSE. So the NSE does not mark conversations unread.

**Revised approach for NSE**: Instead of querying GRDB, simply increment the badge by 1 for each notification delivered. This is simpler and avoids the complexity of the NSE needing to know the unread state. The main app will correct the badge to the exact count when it opens.

Actually, the simplest and most robust approach: **use `UNMutableNotificationContent.badge` in the NSE to increment**. But iOS doesn't support atomic increment — you set an absolute number. So the NSE would need to read the current badge and add 1, which is racy if multiple notifications arrive simultaneously.

**Simplest correct approach**: Use the **main app only** for badge management. The badge updates reactively from GRDB observation. For background notifications, rely on the push payload's `badge` field set by the backend — but we don't control the backend push payload format.

**Final approach — app-only, GRDB-reactive**:

The app observes the unread conversation count from GRDB and sets the badge whenever it changes. When the app is foregrounded, it clears the badge to zero. This means:

- While the app is running: badge reflects live unread count (but the user is in the app, so the badge isn't visible anyway)
- When the app goes to background: badge shows the correct unread count at that moment
- When new messages arrive while backgrounded: the badge won't update until the app is foregrounded (the NSE doesn't touch the badge)
- When the app is foregrounded: badge clears to zero

This is the simplest approach that satisfies the requirement. The badge won't show a count while the app is backgrounded and new messages arrive — but that's acceptable for v1. If we need real-time background badge updates later, we can add NSE badge management.

**Actually, even simpler**: Just clear the badge on foreground, set it on background. The user sees the badge on the home screen, taps the app, badge clears. That's the core UX.

### Implementation

#### 1. `UnreadBadgeManager` (new, in ConvosCore)

A lightweight actor that observes the unread conversation count from GRDB and exposes it. The app layer uses this to set `UNUserNotificationCenter.current().setBadgeCount()`.

```swift
public actor UnreadBadgeManager {
    private let databaseReader: any DatabaseReader
    private var observation: AnyDatabaseCancellable?

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func unreadCount() throws -> Int {
        try databaseReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.isUnread == true)
                .fetchCount(db)
        }
    }
}
```

Actually, we don't even need a new class. We can do this entirely in `ConvosApp` / `ConvosAppDelegate` with a few lines.

#### 2. Clear badge on foreground (`ConvosAppDelegate`)

In `applicationDidBecomeActive` or via `NotificationCenter` observation of `UIApplication.didBecomeActiveNotification`:

```swift
UNUserNotificationCenter.current().setBadgeCount(0)
```

#### 3. Set badge on background (`ConvosAppDelegate`)

In `applicationDidEnterBackground` or via `UIApplication.didEnterBackgroundNotification`:

Query the unread count from GRDB and set the badge.

#### 4. NSE sets badge on notification delivery (stretch)

For real-time background updates, the NSE can query the shared GRDB database for the unread count and set `content.badge`. This requires the NSE to have access to the `conversationLocalState` table and perform a count query. Since the NSE already has full GRDB access, this is straightforward.

### Chosen approach (minimal, correct)

1. **Clear badge to 0** when the app becomes active (`didBecomeActiveNotification`)
2. **Set badge to unread count** when the app enters background (`didEnterBackgroundNotification`)
3. **NSE sets badge** on each notification delivery by querying GRDB for the unread count

This gives us:
- Badge clears instantly when user opens the app ✅
- Badge shows correct count when app is in background ✅
- Badge updates when new notifications arrive while backgrounded ✅ (via NSE)
- No need for the user to manually mark conversations as read ✅

### Files changed

| File | Change |
|------|--------|
| `ConvosAppDelegate.swift` | Add `didBecomeActive` → clear badge, `didEnterBackground` → set badge from GRDB |
| `ConvosApp.swift` | Pass `databaseReader` to the delegate for unread count queries |
| `NotificationService.swift` | Set `content.badge` from GRDB unread count on notification delivery |

### Edge cases

| Scenario | Behavior |
|----------|----------|
| App opened with 5 unread | Badge clears to 0 immediately |
| 3 notifications while backgrounded | NSE sets badge to accurate unread count on each delivery |
| User marks all as read in-app | Badge updates to 0 on next background entry |
| No notification permission | `setBadgeCount` still works — badge permission is separate from alert/sound |
| App killed by system | Badge persists at last set value until next launch |
| Multiple NSE instances | GRDB provides serialized access, count is always consistent |
