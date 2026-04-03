# App Icon Badge Count

> **Branch**: `jarod/app-icon-badge-count`

## Goal

Show a badge on the app icon when messages arrive while the app is backgrounded. Clear the badge when the user opens the app — no need to mark individual conversations as read.

## Design

The badge is a "you have unseen notifications" indicator, not a mirror of the unread conversation count.

### Two touch points

1. **NSE sets the badge** when delivering a notification for a new message (not reactions)
2. **App clears the badge to zero** when foregrounded

### NSE badge logic

When the NSE delivers a processed notification:
- Count currently delivered notifications via `UNUserNotificationCenter.current().deliveredNotifications()`
- Set `content.badge = delivered.count + 1` (the +1 accounts for the notification being delivered now)
- Skip badge update for reaction notifications (reactions should not increment the count)

When the user opens the app, `didBecomeActiveNotification` fires and clears the badge to 0. Since iOS also clears the notification center when the user opens the app, the delivered count resets naturally.

### What this means for the user

- App backgrounded, 3 messages arrive → badge shows 3
- User opens app → badge clears to 0 immediately, regardless of whether they read conversations
- Reactions arrive while backgrounded → badge does not increment
- App killed, notifications arrive → NSE still sets badge (it runs independently)

## Files changed

| File | Change |
|------|--------|
| `ConvosAppDelegate.swift` | Clear badge to 0 on `didBecomeActiveNotification` |
| `NotificationService.swift` | Set `content.badge` from delivered notification count (skip reactions) |
| `PushNotificationPayload.swift` | Add `isReaction` flag to `DecodedNotificationContent` |
| `MessagingService+PushNotifications.swift` | Set `isReaction` on reaction notifications |

## Edge cases

| Scenario | Behavior |
|----------|----------|
| App opened | Badge clears to 0 immediately |
| 3 messages while backgrounded | Badge shows 3 |
| Reaction while backgrounded | Badge does not increment |
| App killed, messages arrive | NSE sets badge independently |
| No notification permission | `setBadgeCount(0)` still works on foreground |
