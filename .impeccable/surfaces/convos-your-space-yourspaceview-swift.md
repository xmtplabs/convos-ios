---
version: 1
slug: "convos-your-space-yourspaceview-swift"
primary_target: "Convos/Your Space/YourSpaceView.swift"
related_targets: ["Convos/Your Space/YourSpaceContextViews.swift","Convos/Your Space/YourSpaceSheets.swift","Convos/Your Space/YourSpaceModels.swift","Convos/Your Space/YourSpaceSharing.swift","ConvosCore/Sources/ConvosCore/Storage/Repositories/ContextLibraryRepository.swift","QAAutomationServer/QAAutomationServerTest.swift","Convos/MainTabView.swift"]
---

# Your Space surface brief

- Scope and mode: the authenticated iOS landing surface; Operate mode with a private, editorial briefing rather than an inbox.
- Audience: an existing Convos user who belongs to multiple conversations and wants to understand what changed without opening each one.
- Job and action: orient from a private narrative, jump into one of three recent Convos, open Me & My Stuff, work with a personal agent in private, or explicitly stage a selected item into a chosen destination's composer.
- Runtime constraint: the bounded home scroll view owns viewport sizing; the anchored switcher overlays it, and the main-actor-scheduled local context observation keeps only the latest 500 combined results from at most 500 loaded convos. Useful-detail extraction scans at most 5,000 eligible messages and keeps at most 250 detected facts so launch sync cannot starve interaction or start GRDB's immediate scheduler off-main.
- Proof and content: real local conversation previews, unread state, content-first photo/file/link/map previews, editable remembered addresses/numbers/details, source convo names, verified sender metadata, and relative time. The production summarization service remains an open data boundary.
- Constraints: private by default; never auto-send or imply server-side synthesis; a connected Codex receives only the bounded snapshot the user enables and works inside the paired Mac workspace; personal agents are never group participants and cannot be messaged by group members; preserve start, join, pairing, deep-link, stale-device, settings, and conversation flows.
- Direction: a quiet personal signal desk using Convos neutrals and dramatic editorial type. Reading order is narrative → three flat recent-Convo rows → one expressive Me & My Stuff summary → the permanent private personal-agent boundary → three recent group agents with inline See all. The full Me destination owns photos, links, files, connections, useful details, search, provenance, explicit Edit, and sharing. The bottom agent command bar remains between native More and chat controls.
- Navigation: the profile avatar pushes Me & My Stuff; a separate gear opens current settings. Recent Convos push a full-height transcript focus with a visible Back to Your Space control rather than opening the Home-backed half sheet.
- Agent truth: Codex, Town, and Tasklet are live; Tasklet stays directly below Town. Claude Code, Hermes, and OpenClaw are previews. Grok Bot and the bottom Connect MCP row are Coming soon. Added live providers stay in Your Space and Talk to selectors if credentials disappear, and tapping them opens reconnect.
- Memorable moment: the launch sentence resolves into three places to go, then the Me card makes a growing private library feel like a personal possession rather than a settings dashboard.
- Pinned shell: `YS-SHELL-2026-08-18`, recorded durably in `docs/your-space-shell-reference.md`; this user-supplied shell reference replaced a generated concept seed.
- Unresolved: production policy and API for richer semantic summaries beyond deterministic message-preview synthesis.
