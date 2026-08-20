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
- The orange group-local Convos agent is always the first and initially selected lane. Its verified live member replaces the fallback when available; a syncing or missing member never lets a personal agent silently become the group default.
- Tapping the avatar opens a native selector with that single group agent first, external agents the user has actually added after it, and Ghost Mode last. Sample personas such as Flight Tracker and Shane's Agent never appear as real choices.
- Long-pressing any group message exposes **Send to agent** beneath Reply. Selecting it closes the context menu and opens a destination-only native sheet using the exact Talk to roster and order: the group-local Convos agent first, connected personal agents next, and Ghost last. The sheet contains no context or add-agent controls.
- Choosing a destination sends only the selected message plus its visible sender label without switching tabs, changing the selected lane, clearing that lane's draft, or attaching neighboring transcript/Home context. A disconnected personal-agent row routes through its existing provider reconnect flow.
- The source message receives a compact private agent-icon receipt aligned like a reaction. Tapping the icon states **Sending to …**, **Message sent to …**, or **Couldn’t send to …**. The receipt is device-local UI state and must never be encoded as an XMTP emoji reaction visible to the group.
- **Connect an agent from another convo** sits immediately above **Add an external agent**. It presents an owner-scoped agent list and a full-screen review of the portable agent layer.
- Linking creates one two-way shared memory and makes all of the agent's abilities, connections, and installed skills available in both convos. Raw transcripts, Ghost Mode, private DMs, member lists, and unsaved files never cross.
- Confirmation warns that people in either convo can influence future saved memory. The linked lane's settings show the full shared layer and allow the owner to disconnect it from the current convo without deleting the original agent.
- **Add an external agent** sits immediately before Ghost Mode. It presents provider-specific setup for live Codex, Town, Tasklet, and multi-agent Grok Bot; previews for Claude Code, Hermes, and OpenClaw; and a Coming soon row for Connect MCP. Tasklet sits directly below Town and Connect MCP stays last.
- A personal external lane is private to its owner and is not automatically connected to any group. Added provider identities persist independently of credentials; a disconnected row remains in Talk to and opens the provider-specific reconnect flow.
- Each local prototype lane keeps its own draft, transcript, and working state. Switching lanes never redirects or cancels in-flight work.
- Each local prototype transcript is restored per Convo from this-device-only Keychain storage, capped to a bounded history per lane. Forwarded Grok Bot text and returned messages therefore remain visible after leaving and reopening the Convo.
- Ghost Mode uses the custom ghost glyph, the heading **Completely off the record.**, and message-level Share actions. The native **Send to** menu states that only the selected message leaves.
- Every Convo uses three peer, full-screen surfaces selected by one fixed bottom switcher in this order: **Desktop / Group / Agent**. A normal Convo tap always opens Group; only an explicit agent action or agent-DM notification opens Agent directly.
- Desktop owns the unobstructed group WebView. Group owns the group transcript and composer. Agent owns the private agent transcript and composer. Switching surfaces keeps their navigation, transcript position, and drafts mounted.
- The top-left Back control is always present and returns directly to the previous Convos list. Desktop browser pages consume Back only while Desktop is active. Desktop and Group show the group identity/settings control in the middle and Invite at top right; Agent intentionally shows neither group control.
- The full-screen shell does not expose half/collapsed detents or an invisible resize target. Native agent prototypes must not overlay controls or intercept touches above the Desktop WebView.
- The group-agent model picker offers ChatGPT, Claude, Grok, Gemini, and DeepSeek as the current non-production catalog.

## Truth boundary

This interaction is available only in non-production environments until the server contract is implemented. Prototype agents and Ghost messages are local demonstrations. Production Ghost copy requires an isolated runtime/memory namespace plus approved retention, provider, logging, deletion, and export policies.

Ghost sharing completes inside local prototype lanes. The group-local agent uses its real private XMTP DM; connected external agents use their existing provider bridges, and a failed background dispatch must resolve the local receipt as failed. Cross-convo links require ownership and membership checks on both convos, visible link state, content-class boundaries, and immediate revocation. Live Codex, Town, Tasklet, and named Grok Bot credentials use their existing secure device stores; Coming soon and preview providers never request secrets. A group-message handoff copies only the explicitly selected row and sender label. Connect MCP never copies context in this build. Home edits remain proposals until a server-backed preview and publish contract exists.

## Visual language

- Reuse the existing dark agent surface, raised message bubbles, native list/action-sheet behavior, and floating tab capsule.
- Distinguish lanes with simple circular glyphs: blue flight, black personal agent, lava Space Abilities, purple Ghost Mode.
- Preserve at least 44-point targets, explicit accessibility labels and hints, and high-contrast text/icon combinations in light and dark appearances.

## Acceptance path

1. Open a recent Convo from Your Space and confirm it lands directly in the full-screen Group surface.
2. Confirm **Desktop / Group / Agent** remains fixed at the bottom, then move between all three without losing the current surface state.
3. On Desktop and Group, confirm Back is top left, group settings is centered, and Invite is top right. On Agent, confirm only Back remains.
4. Use Back from Group or Agent and confirm it returns directly to the Home hierarchy. From a pushed Desktop browser page, confirm Back pops the page before leaving the Convo.
5. Reopen, tap **Agent**, and confirm the orange group-local agent is selected before opening Talk to. Confirm that same group agent remains first, added external providers follow it, and Ghost appears last.
6. Disconnect an added live provider and confirm its row remains and routes to reconnect.
7. Inspect Add an external agent: Tasklet follows Town; Grok Bot supports multiple named harnesses; Connect MCP is the final Coming soon row.
8. Enter text in two real/connected lanes and confirm drafts stay separate.
9. Open Ghost Mode, share one message, and confirm the UI identifies the single-message scope.
10. Open the model picker and confirm ChatGPT, Claude, Grok, Gemini, and DeepSeek appear.
11. Long-press a group message, choose **Send to agent**, and confirm the destination sheet matches Talk to without setup rows.
12. Send to a connected personal agent and confirm the group remains on screen while the source message gains a tappable private receipt naming that agent.
13. Open that agent lane and confirm the forwarded text is present without replacing its existing draft; leave and reopen the Convo and confirm the transcript remains.
