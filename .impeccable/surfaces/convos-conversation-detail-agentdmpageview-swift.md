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
- Tapping the avatar opens a native selector with verified agents available in the current group, external agents the user has actually added, and Ghost Mode. Sample personas such as Flight Tracker and Shane's Agent never appear as real choices.
- **Connect an agent from another convo** sits immediately above **Add an external agent**. It presents an owner-scoped agent list and a full-screen review of the portable agent layer.
- Linking creates one two-way shared memory and makes all of the agent's abilities, connections, and installed skills available in both convos. Raw transcripts, Ghost Mode, private DMs, member lists, and unsaved files never cross.
- Confirmation warns that people in either convo can influence future saved memory. The linked lane's settings show the full shared layer and allow the owner to disconnect it from the current convo without deleting the original agent.
- **Add an external agent** sits immediately before Ghost Mode. It presents provider-specific setup for live Codex, Town, and Tasklet; previews for Claude Code, Hermes, and OpenClaw; and Coming soon rows for Grok Bot and Connect MCP. Tasklet sits directly below Town and Connect MCP stays last.
- A personal external lane is private to its owner and is not automatically connected to any group. Added provider identities persist independently of credentials; a disconnected row remains in Talk to and opens the provider-specific reconnect flow.
- Each local prototype lane keeps its own draft, transcript, and working state. Switching lanes never redirects or cancels in-flight work.
- Ghost Mode uses the custom ghost glyph, the heading **Completely off the record.**, and message-level Share actions. The native **Send to** menu states that only the selected message leaves.
- Every Convo uses three peer, full-screen surfaces selected by one fixed bottom switcher in this order: **Desktop / Group / Agent**. A normal Convo tap always opens Group; only an explicit agent action or agent-DM notification opens Agent directly.
- Desktop owns the unobstructed group WebView. Group owns the group transcript and composer. Agent owns the private agent transcript and composer. Switching surfaces keeps their navigation, transcript position, and drafts mounted.
- The top-left Back control is always present and returns directly to the previous Convos list. Desktop browser pages consume Back only while Desktop is active. Desktop and Group show the group identity/settings control in the middle and Invite at top right; Agent intentionally shows neither group control.
- The full-screen shell does not expose half/collapsed detents or an invisible resize target. Native agent prototypes must not overlay controls or intercept touches above the Desktop WebView.
- The group-agent model picker offers ChatGPT, Claude, Grok, Gemini, and DeepSeek as the current non-production catalog.

## Truth boundary

This interaction is available only in non-production environments until the server contract is implemented. Prototype agents and Ghost messages are local demonstrations. Production Ghost copy requires an isolated runtime/memory namespace plus approved retention, provider, logging, deletion, and export policies.

Ghost sharing completes inside local prototype lanes. A real agent destination must show an explicit preview-only/not-sent result until the server export contract is connected. Cross-convo links require ownership and membership checks on both convos, visible link state, content-class boundaries, and immediate revocation. Live Codex, Town, and Tasklet credentials use their existing secure device stores; Coming soon and preview providers never request secrets. Grok Bot and Connect MCP never copy context in this build. Home edits remain proposals until a server-backed preview and publish contract exists.

## Visual language

- Reuse the existing dark agent surface, raised message bubbles, native list/action-sheet behavior, and floating tab capsule.
- Distinguish lanes with simple circular glyphs: blue flight, black personal agent, lava Space Abilities, purple Ghost Mode.
- Preserve at least 44-point targets, explicit accessibility labels and hints, and high-contrast text/icon combinations in light and dark appearances.

## Acceptance path

1. Open a recent Convo from Your Space and confirm it lands directly in the full-screen Group surface.
2. Confirm **Desktop / Group / Agent** remains fixed at the bottom, then move between all three without losing the current surface state.
3. On Desktop and Group, confirm Back is top left, group settings is centered, and Invite is top right. On Agent, confirm only Back remains.
4. Use Back from Group or Agent and confirm it returns directly to the Home hierarchy. From a pushed Desktop browser page, confirm Back pops the page before leaving the Convo.
5. Reopen, tap **Agent**, open Talk to, and confirm only verified/current-group agents, added external providers, and Ghost appear.
6. Disconnect an added live provider and confirm its row remains and routes to reconnect.
7. Inspect Add an external agent: Tasklet follows Town; Grok Bot is Coming soon; Connect MCP is the final Coming soon row.
8. Enter text in two real/connected lanes and confirm drafts stay separate.
9. Open Ghost Mode, share one message, and confirm the UI identifies the single-message scope.
10. Open the model picker and confirm ChatGPT, Claude, Grok, Gemini, and DeepSeek appear.
