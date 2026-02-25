# XMTP Conversation Stream Not Delivering New Groups

## Summary

When a member is added to an XMTP group, the conversation stream (`client.conversations.stream(type: .groups)`) does not reliably deliver the new group to the added member. In testing, the stream either delivers after 45+ seconds or never delivers at all, even though the member was successfully added on the network.

**Likely explanation:** The conversation stream subscribes to topics based on the client's known groups at subscription time. When the client is added to a new group after the stream starts, the stream has no topic subscription for that group and never delivers it. Only `syncAllConversations` + `listGroups` can discover groups added after stream subscription. This needs confirmation from the XMTP team.

## Environment

- XMTP iOS SDK (`xmtp-ios`)
- Network: `dev`
- iOS 26.2 Simulator
- Two separate XMTP clients (simulating two users)

## Steps to Reproduce

Write a standalone test or script using the XMTP iOS SDK directly (no Convos app code). The test needs two XMTP clients — a "host" and a "joiner."

### Setup

1. Create two XMTP clients on the `dev` network, each with their own wallet/identity.
2. On the **host** client, create a group conversation.

### Test

3. On the **joiner** client, start a conversation stream:
   ```swift
   let stream = try joiner.conversations.stream(type: .groups)
   Task {
       for try await conversation in stream {
           print("[STREAM] Received group: \(conversation.id) at \(Date())")
       }
       print("[STREAM] Stream ended")
   }
   ```
   Also call `syncAllConversations` and `sync()` to make sure the client is up to date before starting the stream.

4. Wait a few seconds for the stream to fully subscribe.

5. On the **host** client, add the joiner to the group:
   ```swift
   try await group.addMembers(inboxIds: [joinerInboxId])
   print("[HOST] Added joiner at \(Date())")
   ```

6. Record the timestamp when the host adds the joiner, and the timestamp when (if) the joiner's stream delivers the group.

7. Wait at least 120 seconds.

### Expected Result

The joiner's conversation stream should deliver the new group within a few seconds of being added.

### Actual Result (observed in Convos)

- **Test 1 (CLI host, simulator joiner):** Stream delivered the group after **45 seconds**.
- **Test 2 (simulator host, simulator joiner):** Stream **never delivered** the group. Waited over 4 minutes with zero stream events.

### Fallback Verification

8. After the stream fails to deliver, call `syncAllConversations` on the joiner client, then `listGroups`:
   ```swift
   try await joiner.conversations.syncAllConversations()
   let groups = try joiner.conversations.listGroups()
   print("Groups after sync: \(groups.map { $0.id })")
   ```

   In our testing, `syncAllConversations` + `listGroups` **does** find the group. This confirms the member was added on the network — the stream just didn't deliver it.

## Key Details

- The joiner's stream is started BEFORE the host adds them. The stream is active and subscribed.
- The joiner's client has called `syncAllConversations` before starting the stream (during initial sync).
- The stream uses `type: .groups` with no consent state filter.
- The group's consent state on the joiner is expected to be `.unknown` (they didn't create it).
- There are no errors thrown by the stream — it simply doesn't yield the new conversation.

## What We Need to Understand

1. **Is the conversation stream expected to deliver groups that the client is added to after the stream starts?** Or does it only deliver groups created after subscription?
2. **Is there a known latency or reliability issue with the conversation stream on the `dev` network?**
3. **Does `syncAllConversations` need to be called for the stream to pick up groups the client was added to?** If so, is there a recommended pattern for detecting new group membership besides the stream?
4. **Does the stream filter by consent state internally?** Could `.unknown` consent groups be silently filtered?

## Workaround We're Considering

If the stream is unreliable for this use case, we plan to add a periodic `syncAllConversations` call during the join-wait period in our app, with exponential backoff (e.g., 3s, 6s, 12s, 24s). After each sync, we'd call `listGroups` and process any newly discovered groups. This would run alongside the stream as a fallback.

Before implementing this, we want to confirm whether this is expected SDK behavior or a bug that will be fixed.
