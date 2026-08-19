---
version: 1
slug: "convos-your-space-yourspaceview-swift"
primary_target: "Convos/Your Space/YourSpaceView.swift"
related_targets: ["Convos/Your Space/YourSpaceContextViews.swift","Convos/Your Space/YourSpaceSheets.swift","Convos/Your Space/YourSpaceModels.swift","Convos/Your Space/YourSpaceSharing.swift","ConvosCore/Sources/ConvosCore/Storage/Repositories/ContextLibraryRepository.swift","QAAutomationServer/QAAutomationServerTest.swift","Convos/MainTabView.swift"]
---

# Your Space surface brief

- Scope and mode: the authenticated iOS landing surface; Operate mode with a private, editorial briefing rather than an inbox.
- Audience: an existing Convos user who belongs to multiple conversations and wants to understand what changed without opening each one.
- Job and action: connect recent people, updates, attention, and owned assets across convos; make new private context; open the right convo or explicitly stage a selected item into a chosen destination's composer.
- Runtime constraint: the bounded home scroll view owns viewport sizing; the anchored switcher overlays it, and the main-actor-scheduled local context observation keeps only the latest 500 supported items from at most 500 loaded convos so launch sync cannot starve interaction or start GRDB's immediate scheduler off-main.
- Proof and content: real local conversation previews, unread state, supported attachments and link previews, source convo names, verified sender metadata, and relative time. The production summarization service remains an open data boundary.
- Constraints: private by default; never auto-send or imply server-side synthesis; preserve existing start, join, pairing, deep-link, stale-device, settings, and conversation flows.
- Direction: a quiet personal signal desk using Convos neutrals, dramatic editorial type, one inverted attention surface, and glass only for persistent controls.
- Memorable moment: the launch sentence reads like a live mad-lib across people and convos, then resolves into an editable personal card and a browsable library of everything the user is carrying across them.
- Pinned shell: `YS-SHELL-2026-08-18`, recorded durably in `docs/your-space-shell-reference.md`; this user-supplied shell reference replaced a generated concept seed.
- Unresolved: production policy and API for richer semantic summaries beyond deterministic message-preview synthesis.
