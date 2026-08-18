---
version: 1
slug: "convos-conversation-detail-agentdmpageview-swift"
primary_target: "Convos/Conversation Detail/AgentDmPageView.swift"
related_targets: ["Convos/Conversation Detail/Conversation Sheet/AgentChatPrototype.swift","Convos/Conversation Detail/Conversation Sheet/ConvoAgentMemoryLinkPrototype.swift","Convos/Conversation Detail/Conversation Sheet/ExternalAgentPrototype.swift","Convos/Conversation Detail/Conversation Sheet/AgentComposerBar.swift","Convos/Conversation Detail/ConversationView.swift","Convos/Conversation Detail/Conversation Sheet/ConversationTabBar.swift"]
---

# Agent chat lanes and Ghost Mode prototype

## Purpose

The agent side of a conversation is a private, controllable workspace. The active agent is visible at the composer, switching lanes is immediate, and Ghost Mode gives the user a deliberately separate place to think before sharing exactly one chosen result.

## Interaction contract

- A 44-point circular avatar sits immediately left of the agent composer. It always identifies the active lane.
- Tapping the avatar opens a native selector with Flight Tracker, Shane's Agent, Space Abilities, agents linked from other convos, connected external agents, and Ghost Mode. Real verified agents may replace the matching prototype row.
- **Connect an agent from another convo** sits immediately above **Add an external agent**. It presents an owner-scoped agent list and a full-screen review of the portable agent layer.
- Linking creates one two-way shared memory and makes all of the agent's abilities, connections, and installed skills available in both convos. Raw transcripts, Ghost Mode, private DMs, member lists, and unsaved files never cross.
- Confirmation warns that people in either convo can influence future saved memory. The linked lane's settings show the full shared layer and allow the owner to disconnect it from the current convo without deleting the original agent.
- **Add an external agent** sits immediately before Ghost Mode. It presents a full-screen context-handoff explanation for Codex, Claude Code, Hermes, OpenClaw, and GrokBot.
- Adding an external agent creates a handoff lane, never a fake chat. The lane lets the user select one hour, 24 hours, seven days, or all available group history; optionally include group desktop information; copy one clearly scoped context block; and open the provider's fixed web destination to paste it.
- External context never travels in a URL or automatic request. Ghost Mode, private agent chats, member DMs, other convos, membership lists, and unsaved files remain excluded.
- **Copy key** demonstrates a future one-time, revocable Home return connector. The prototype key is visibly demo-only and cannot write to Convos; production access is limited to visible Home summaries and link/widget update proposals.
- Each local prototype lane keeps its own draft, transcript, and working state. Switching lanes never redirects or cancels in-flight work.
- Ghost Mode uses the custom ghost glyph, the heading **Completely off the record.**, and message-level Share actions. The native **Send to** menu states that only the selected message leaves.
- Home remains an unobstructed WebView owned by the desktop surface. Native agent prototypes must not overlay controls or intercept touches above that WebView.
- Choosing a different Group/Agent tab opens the persistent sheet fully. Tapping the already-selected tab toggles fully open/collapsed, while drag behavior remains available.

## Truth boundary

This interaction is available only in non-production environments until the server contract is implemented. Prototype agents and Ghost messages are local demonstrations. Production Ghost copy requires an isolated runtime/memory namespace plus approved retention, provider, logging, deletion, and export policies.

Ghost sharing completes inside local prototype lanes. External handoff destinations are omitted from Ghost's message-level send list because they use an explicit group-context export flow. Cross-convo links require ownership and membership checks on both convos, visible link state, content-class boundaries, and immediate revocation. External return pairing codes must be short-lived and exchanged server-side; connector credentials never enter the iOS client or model prompt. Home edits remain proposals until a server-backed preview and publish contract exists.

## Visual language

- Reuse the existing dark agent surface, raised message bubbles, native list/action-sheet behavior, and floating tab capsule.
- Distinguish lanes with simple circular glyphs: blue flight, black personal agent, lava Space Abilities, purple Ghost Mode.
- Preserve at least 44-point targets, explicit accessibility labels and hints, and high-contrast text/icon combinations in light and dark appearances.

## Acceptance path

1. Open any convo in a non-production build and tap **Agent**; the sheet opens fully.
2. Tap the avatar and select each of the four lanes.
3. Enter text in two lanes and confirm their drafts stay separate.
4. Send in one lane, switch away while it works, and return to the completed response.
5. Open Ghost Mode, share one message to an agent or the desktop, and confirm the UI identifies the single-message scope.
6. Tap selected **Agent** to collapse and reopen; switch to **Group** and confirm it opens fully.
7. Choose **Add an external agent**, add GrokBot, select a time window, toggle group desktop context, copy the demo context, open GrokBot, and copy the visibly non-functional demo return key.
8. Choose **Connect an agent from another convo**, select an owned agent, review the warning and full portable layer, link it, and confirm its shared lane and disconnect control appear.
