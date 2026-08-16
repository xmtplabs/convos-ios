---
version: 1
slug: "convos-conversation-detail-agentdmpageview-swift"
primary_target: "Convos/Conversation Detail/AgentDmPageView.swift"
related_targets: ["Convos/Conversation Detail/Conversation Sheet/AgentChatPrototype.swift","Convos/Conversation Detail/Conversation Sheet/ExternalAgentPrototype.swift","Convos/Conversation Detail/Home/DesktopAgentPrototype.swift","Convos/Conversation Detail/Conversation Sheet/AgentComposerBar.swift","Convos/Conversation Detail/ConversationView.swift","Convos/Conversation Detail/Conversation Sheet/ConversationTabBar.swift"]
---

# Agent chat lanes and Ghost Mode prototype

## Purpose

The agent side of a conversation is a private, controllable workspace. The active agent is visible at the composer, switching lanes is immediate, and Ghost Mode gives the user a deliberately separate place to think before sharing exactly one chosen result.

## Interaction contract

- A 44-point circular avatar sits immediately left of the agent composer. It always identifies the active lane.
- Tapping the avatar opens a native selector with Flight Tracker, Shane's Agent, Space Abilities, connected external agents, and Ghost Mode. Real verified agents may replace the matching prototype row.
- **Add an external agent** sits immediately before Ghost Mode. It presents a full-screen, provider-specific setup explanation for Codex, Claude Code, Hermes, OpenClaw, and a Convos GrokBot powered by xAI.
- Connecting is explicitly a local demo. Each connected external lane exposes per-conversation access for private Home editing, group participation, and scoped member DMs; all access defaults private/off except the user's own Home read/write permission.
- Each local prototype lane keeps its own draft, transcript, and working state. Switching lanes never redirects or cancels in-flight work.
- Ghost Mode uses the custom ghost glyph, the heading **Completely off the record.**, and message-level Share actions. The native **Send to** menu states that only the selected message leaves.
- The Home surface exposes a compact **From the chat** link shelf. Real links from group messages become cards and determine the count; clearly labeled Demo cards fill the prototype when needed. Each card has an agent affordance that opens the Agent sheet fully with an object-specific, preview-first edit draft.
- Choosing a different Group/Agent tab opens the persistent sheet fully. Tapping the already-selected tab toggles fully open/collapsed, while drag behavior remains available.

## Truth boundary

This interaction is available only in non-production environments until the server contract is implemented. Prototype agents and Ghost messages are local demonstrations. Production Ghost copy requires an isolated runtime/memory namespace plus approved retention, provider, logging, deletion, and export policies.

Ghost sharing completes inside local prototype lanes. A real agent destination must show an explicit preview-only/not-sent result until the server export contract is connected. External provider credentials must terminate at the server gateway and never be stored on the iOS client. Home edits remain proposals until a server-backed preview and publish contract exists.

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
7. Choose **Add an external agent**, inspect every provider, connect one, and confirm its access controls and chat lane appear.
8. On Home, open a link card, then tap its agent avatar and confirm Agent opens fully with the relevant card named in the draft.
