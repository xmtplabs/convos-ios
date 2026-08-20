# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

People who participate in several private Convos and want to understand what changed, who needs attention, and what matters without opening every conversation one by one.

## Product Purpose

Convos is an everyday private messenger for the surveillance age. This prototype makes the app's default destination a private personal space that connects context across a person's conversations, surfaces meaningful updates, and helps them decide where to act next.

Success means opening Convos immediately answers “what is new and what deserves my attention?” while keeping every underlying conversation easy to reach.

## Positioning

The home screen is not a replacement inbox. It is a private, continuously growing layer of personal context assembled from the user's Convos, with three bounded recent-conversation shortcuts so ordinary messaging never becomes harder. It can help the user remember people, notice changes across groups, and selectively bring personal context back into a specific conversation without making that context public by default.

## Operating Context

- The user lands in “Your Space” every time they open the app.
- The title control at the top opens every conversation in a panel that drops from directly beneath the header, keeps Your Space first, and places search above the convo list.
- A top-right add control starts a new conversation or joins one by scanning a QR code.
- The profile image at top left opens Me & My Stuff. App settings is available from the gear inside that profile section, not from Home.
- A native overflow menu exposes connections, private file upload, stored files, home customization, and the conversations contributing to the private space.
- The bottom dock keeps a visible personal-agent command bar as the primary action, with More on the left and chat on the right. When an external harness is connected in the prototype, the bar names it and exposes a native harness switcher.
- Contacts are selected in the invite flow for a conversation rather than occupying a permanent bottom-level destination.
- Home opens directly on the three most recent real Convos as flat rows. The private serif briefing moves to the very bottom of the scroll, immediately below Your Space footprint when that widget is enabled, so useful destinations lead and the summary stays available without dominating launch. Opening a Convo pushes directly into Group inside a full-screen conversation shell. A fixed **Desktop / Group / Agent** switcher moves between the group WebView, group chat, and private agent lane without a half-sheet. Back remains top left on every surface. Desktop and Group show centered group settings plus Invite at top right; Agent intentionally omits both. Back returns directly to the prior Convos list, except on Desktop where an open browser page is popped first.
- The Me & My Stuff Home card opens a dedicated personal library for the editable contact card, photos, links, files, connections, automatically detected useful message details, and supported assets from loaded convos by type and provenance. Edit is a distinct action on that destination.
- Useful details are not contact-card fields: Me & My Stuff shows compact Addresses, Phone numbers, Email, and All useful details filter rows, while the All Context sheet renders every indexed fact as a searchable full-width card with its source message, sender, convo, time, source-convo link, sender-message action, and share action.
- “Agents across your convos” always starts with the three most recent rows and expands inline with See all. Each row identifies the agent and source convo and opens that agent's private lane.
- An always-present “Bring personal agents to Convos” section and the More menu open the external-agent connection flow. It explicitly states that the agent is private to the user, is not connected to a group, and cannot be messaged by group members. Codex can pair with the user's authenticated Mac app-server through a revocable capability token. Town connects through its MCP server, while Tasklet uses the same one-use MCP return bridge plus a Tasklet webhook automation. Grok Bot connects once to an outbound-only computer relay: while waiting, Convos lets the user copy the private pairing token into that relay, then expands every enabled named agent into its own private harness. Users can return to enable more without replacing their existing Grokbots. Claude Code, Hermes, and OpenClaw remain labeled previews; Connect MCP remains Coming soon. Results and individual returned links can be saved into Your Space and explicitly staged into a chosen convo.
- The Talk to selector always starts with the single group-local Convos agent and selects it by default: the verified live lane when available, or its orange fallback while that member is syncing. External agents the user has actually added and every enabled named Grok Bot harness follow it, with Ghost last. It never promotes prototype personas such as Shane's Agent or Flight Tracker as if they were real agents. An added external agent is restored across Your Space and every group selector on that device; if its credential disappears, the row remains and opens the provider-specific reconnect flow.
- Long-pressing a group message offers **Send to agent**. Its dark destination sheet uses that same ordered roster—group-local Convos agent, connected personal agents, then Ghost—and also offers universal links to ChatGPT, Claude, and Gemini. Choosing a Convos agent opens that private DM, selects the agent, and stages only the selected message plus its visible sender label in the composer for editing and confirmation; it never auto-sends. A reaction-sized private agent icon remains under the source message. Tapping it opens a **Sent to Agent** drawer naming the agent and explaining that only the user can see the handoff. External personal-agent results always offer **Share to a convo**; the current Convo is pinned first, and selection stages the result in the chosen group composer for editing before send. These markers and local personal-agent transcripts remain device-private and never become group reactions.
- The group-agent model picker offers ChatGPT, Claude, Grok, Gemini, and DeepSeek as the current prototype catalog.
- Any context item may be shared only by explicitly choosing a destination; the app opens that convo with the item staged in its composer for review and never auto-sends it.

## Capabilities and Constraints

- Preserve Convos' invitation-only, identity-per-conversation, local-first privacy model.
- Use the existing conversation store and navigation paths; the prototype must not fabricate real messages or imply that private context has been uploaded.
- Voice transcription and imported files stay on-device. Built-in chat answers remain local and use the currently visible briefing data; when the user selects connected Codex, Town, Tasklet, or a named Grok Bot, the app sends the request and only the explicitly enabled, bounded Your Space snapshot to that connected agent.
- The home experience needs useful loading, empty, unread, and no-attention states.
- The conversation switcher must support many conversations, unread state, search, and direct navigation.
- The context library must support search, type filters, provenance, local notes/photos/voice/files, an editable personal card with bounded custom title-and-info fields, and an explicit add menu for context or connections.
- The first production-grade context index is deliberately bounded to the 500 newest combined results across at most 500 loaded conversations. It indexes supported attachments/link previews plus addresses, phone numbers, and emails detected within the latest 5,000 eligible text messages, capped at 250 useful-detail results. Broader semantic extraction and paging remain separate data-contract decisions.
- Visible context cards render the richest safe preview available: decrypted or local thumbnails, document thumbnails, text excerpts, map snapshots, and cached link artwork. A visible link card may hydrate metadata and artwork through the app's existing bounded rich-link service, then caches the result; background indexing never crawls preview hosts.
- Recent convo previews remain neutral context until the user explicitly saves one. The app must not present them as inferred personal facts without a dedicated suggestion contract.
- The initial prototype may use clearly isolated sample insight content in previews. Production summaries, provenance, ranking, and persistence remain an open data-contract decision.
- Existing notification, deep-link, QR joining, new-conversation, settings, stale-device, and conversation-detail behavior must remain reachable.

## Brand Commitments

- Product name: Convos.
- Voice: direct, human, calm, private, and useful; never surveillance-like or breathlessly “AI.”
- The supplied “Switching Spaces” screenshot is a structural reference for a private landing space and title-bar switcher, not an instruction to copy its visual styling or its “Spaces” terminology.

## Evidence on Hand

- Current iOS application and design tokens in this repository.
- User-supplied concept screenshot at `/var/folders/3n/rwbv43pn3sj51ml6bhqrpl6r0000gn/T/codex-clipboard-3cc6e300-c7b1-40a2-9069-6480c38da797.png`.
- No confirmed production API currently provides cross-conversation summaries, attention ranking, or shareable personal-memory objects; the interface must label preview-only sample data and keep the integration boundary explicit.

## Product Principles

1. Private by default: Your Space belongs to one person, and sharing out is deliberate.
2. Orient before opening: the first screen explains what changed and where attention is valuable.
3. Conversations stay one gesture away: replacing the inbox must not make navigation slower.
4. Context compounds: the surface should become more useful as relationships and conversations grow.
5. Show provenance: every update names its conversation, and names a person only when verified sender metadata is available, so the user can trust and inspect it.

## Accessibility & Inclusion

- Preserve Dynamic Type, VoiceOver labels and ordering, minimum 44-point controls, sufficient contrast, Reduce Motion behavior, and non-color indicators for unread and urgency states.
- Summaries must not require familiarity with a person's display name alone; conversation provenance and explicit action labels remain available to assistive technology.
