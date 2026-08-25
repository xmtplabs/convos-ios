---
version: 1
slug: "convos-your-space-yourspaceview-swift"
primary_target: "Convos/Your Space/YourSpaceView.swift"
related_targets: ["Convos/Your Space/YourSpaceContextViews.swift","Convos/Your Space/YourSpaceSheets.swift","Convos/Your Space/YourSpaceModels.swift","Convos/Your Space/YourSpaceSharing.swift","ConvosCore/Sources/ConvosCore/Storage/Repositories/ContextLibraryRepository.swift","QAAutomationServer/QAAutomationServerTest.swift","Convos/MainTabView.swift"]
---

# Your Space surface brief

- Scope and mode: the authenticated iOS landing surface; Operate mode with a private, editorial briefing rather than an inbox.
- Audience: an existing Convos user who belongs to multiple conversations and wants to understand what changed without opening each one.
- Job and action: orient from one private narrative, catch up on the highest-signal Convo, inspect every agent the person can use and its access, search context across their life, or use an agent/artifact/link/file in any installed chat app.
- Runtime constraint: the bounded home scroll view owns viewport sizing; the anchored switcher overlays it, and the main-actor-scheduled local context observation keeps only the latest 500 combined results from at most 500 loaded convos. Useful-detail extraction scans at most 5,000 eligible messages and keeps at most 250 detected facts so launch sync cannot starve interaction or start GRDB's immediate scheduler off-main.
- Proof and content: real local conversation previews, unread state, human agent ownership, per-Place Listen and speech permissions, content-first photo/file/link/map previews, editable remembered addresses/numbers/details, source Convo names, verified sender metadata, and relative time. The production summarization service remains an open data boundary.
- Constraints: private by default; never auto-send or imply server-side synthesis; external chat history enters only through an explicit share/import or a future transparent connection; connected agents receive only explicitly permitted context; preserve start, join, pairing, deep-link, stale-device, settings, and conversation flows.
- Direction: a quiet personal signal desk using Convos neutrals and dramatic editorial type. Reading order is narrative → one conditional catch-up action plus Agents and Use anywhere → access-aware Agents → Your context → seven recent Convos → optional support. The bottom agent command bar remains between native More and chat controls.
- Navigation: the profile avatar pushes Your context, whose own gear opens current settings. Use anywhere opens All context; each item's share sheet puts Any chat app above Convos destinations. Recent Convos push a full-height transcript focus with a visible Back to Your Space control rather than opening the Home-backed half sheet.
- Agent truth: Codex, Town, Tasklet, and Grok Bot are live; Tasklet stays directly below Town and Grok Bot directly below Tasklet. One Grok Bot computer session exposes its private pairing token only through an explicit copy action while waiting, expands its enabled agents into independently named harnesses across Your Space and Talk to, and remains reopenable to add more. Claude Code, Hermes, and OpenClaw are previews. The bottom Connect MCP row is Coming soon. Added live providers stay in Your Space and Talk to selectors if credentials disappear, and tapping them opens reconnect.
- Memorable moment: the launch sentence resolves into three legible primitives—catch up, Agents, Use anywhere—then a green Listen receipt makes continuous access feel explicit rather than magical.
- Pinned shell: `YS-SHELL-2026-08-18`, recorded durably in `docs/your-space-shell-reference.md`; this user-supplied shell reference replaced a generated concept seed.
- Unresolved: production policy and API for richer semantic summaries beyond deterministic message-preview synthesis; persistent external-chat ingestion requires explicit platform integrations with visible provenance and retention controls.
