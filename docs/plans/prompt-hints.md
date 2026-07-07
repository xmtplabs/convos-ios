# Prompt Hints (dice roll)

> **Status**: Implemented
> **Branch**: `feature/dice-roll-templates`
> **Source of truth**: Notion "Prompt Hints" spec
> **Backend**: separate PR on `convos-backend` (`feature/prompt-hints`)

## Overview

A `dice.fill` control in the Agent Builder's top-right toolbar drops a short, curated prompt snippet into the "What needs done?" composer. Tapping it rolls a random hint; the user can re-roll repeatedly. Hints come from a new public, unauthenticated backend endpoint, are cached on disk and in memory, refreshed once per launch, and surfaced only when the composer is a clean slate. The whole feature is text-only and adds two metrics signals so we can see whether hints actually move the needle on agent creation.

## Problem

When a user makes an agent, the first thing they meet is the empty "What needs done?" composer. The empty box is intimidating: people are unsure what a prompt can contain and reluctant to commit to typing something before they hit the button. That hesitation is a drop-off point right at the top of the agent-creation funnel.

## Goals

- Educate first-time users about what a prompt can contain by showing concrete, varied examples in place.
- Lower the reluctance to try agent creation by giving a one-tap way to fill the box with something usable.
- Make the prompts delightful and a little playful, so rolling the dice is itself an invitation to experiment.

## Non-Goals

- Attachments or connections in the hint flow. Hints are text-only.
- Suggested agent templates inside the builder. Hints are short prompt snippets, not published templates, and are stored in a dedicated table so they never pollute the agent catalog.
- A second prompt surface anywhere outside the Agent Builder.

## Behavior

The dice is an `Image(systemName: "dice.fill")` `ToolbarItem(placement: .topBarTrailing)`, added alongside the existing top-left close button, only in the builder's `.sheet` mode. It follows the project Button pattern (extracted `action`) and its whole `ToolbarItem` is omitted (not just emptied) when hidden, so no space is reserved and the toolbar chain stays cheap to type-check.

### Visibility rule

The dice shows only when all of the following hold:

- The in-memory hint list is non-empty. If nothing is in memory, the dice is hidden entirely (graceful when the endpoint is unseeded or unreachable).
- There are no media attachments, no recorded or in-progress voice memo, and no enabled connections.
- The trimmed composer text is empty, or the box still contains an unedited dice-rolled prompt (`composerTextSource == .dice`).

In the view this reduces to one typed `let`: `isDiceVisible = hints non-empty AND viewModel.allowsDiceRoll`, where `allowsDiceRoll` folds the attachment/voice/connection/text checks into a single `Bool` on the view model. The attachment and connection signals are real properties already on `AgentBuilderViewModel` (`pendingMediaAttachments`, `recordedVoiceMemo` / `isRecordingVoiceMemo`, `enabledConnections`), not invented for this feature.

### Roll

Each tap picks a random hint, excluding the last-shown hint when more than one option exists (no immediate repeats). The roll sets the composer text programmatically, marks the source as dice, flags the build as hint-seeded, increments the tap counter, and fires the per-tap metric. Because the assignment is programmatic, SwiftUI does not call the composer's binding setter, so the source stays `.dice` and the dice remains visible for further re-rolls. The moment the user edits the text, the binding setter flips the source to `.manual` and the dice disappears.

## Technical Design

The feature is split across `ConvosCore` (platform-independent service + API) and the app target (cache model, view model state, view wiring). It builds on macOS, with no UIKit dependencies.

### Three separated state fields, and why they differ

The view model keeps three intentionally distinct fields. Conflating them is the main correctness trap, so they are split by purpose:

- `composerTextSource { manual, dice }` -- drives dice **visibility** only. A custom `Binding` (`composerTextBinding`) replaces the direct `$viewModel.composerText` binding on the text field; its setter marks `.manual` before assigning. SwiftUI calls the setter only on user keystrokes, never on programmatic assignment, so a roll keeps the source `.dice` (dice stays for re-rolls) while a single keystroke flips it to `.manual` (dice hides).
- `fromPromptHint: Bool` -- drives **metrics**. True once a hint seeds the prompt. It persists through edits, because the resulting agent still originated from a hint, and resets to false only when the box is cleared, not when it is edited.
- `promptHintTapCount: Int` -- drives **metrics**. Accumulates dice taps for the builder session (the view model is per-session).

The key distinction: editing a rolled hint hides the dice (visibility, via `composerTextSource`) but keeps `fromPromptHint = true` (metrics). `commit()` clears the text and resets `composerTextSource` and `lastRolledHint`, after the `built_agent` metric has read the flags.

### API layer (ConvosCore)

- `ConvosAPIClient+Models.swift` -- new `ConvosAPI.AgentPromptHintsResponse { hints: [String] }`.
- `ConvosAPIClient.swift` -- protocol method plus concrete `getAgentPromptHints()`: a public, bare (unauthenticated) GET to `v2/agent-prompt-hints`, mirroring `getFeaturedAgentTemplates`.
- `MockAPIClient.swift` -- sample-hints implementation for dev, preview, and tests.
- `Services/PromptHintsService.swift` -- new `PromptHintsServiceProtocol` + `PromptHintsService`, mirroring `SuggestedAgentsService`.
- `Mocks/MockPromptHintsService.swift` -- mirrors `MockSuggestedAgentsService`.
- Test-stub default `getAgentPromptHints()` (returns `[]`) so existing stub conformers keep compiling, plus `PromptHintsServiceTests`.

### Cache model (app target)

`Agent Builder/PromptHintsModel.swift` is an `@Observable @MainActor` class owned by `MainTabView` (`@State = .live()`, injected via `.environment`), so the builder sheet and any builder presented from a descendant conversation screen inherit it.

- Disk cache via `UserDefaults` (`PromptHintsDiskCache`, an injectable seam). `init` hydrates the in-memory `hints` from disk synchronously, so on a warm launch the dice can appear before any network call. The in-memory copy is the single source of truth for the "hints non-empty" gate.
- `loadOnLaunch()` is called once from a `MainTabView` `.task`, guarded by `hasStartedLaunchLoad` (one fetch per process). It refreshes with up to five attempts using exponential backoff + jitter via the shared `TimeInterval.calculateExponentialBackoff(for:)` (30s cap). On success with usable hints it overwrites both memory and disk. An empty payload or total failure leaves the cached hints intact -- the last good cache is never cleared on a failed refetch.
- The backoff is an injectable closure (production default is the shared curve), so unit tests drive the retry loop with no sleeps.
- Hints are sanitized on the way in: trimmed, blank-dropped, and clamped to 240 characters.

`Agent Builder/PromptHintsService+Live.swift` adds the `.live()` factories and a `.preview(hints:)` helper for SwiftUI previews and tests.

### View and view model wiring (app target)

- `AgentBuilderViewModel.swift` -- `ComposerTextSource`, `composerTextBinding`, `fromPromptHint`, `promptHintTapCount`, `allowsDiceRoll`, `rollDice`, and the metrics rewrite.
- `AgentDraftComposer.swift` -- the text field now binds `composerTextBinding` instead of `$viewModel.composerText`.
- `AgentBuilderView.swift` -- reads the model via `@Environment(PromptHintsModel.self)`, computes the typed `isDiceVisible`, and adds `diceToolbarItem` to the existing `.toolbar` block.
- `MainTabView.swift` -- owns `PromptHintsModel`, injects it into the environment, and kicks `loadOnLaunch()` from its launch `.task`.

### Backend contract

`GET /api/v2/agent-prompt-hints` -> `{ "hints": [String] }` where each string is at most 240 characters and the collection is capped at 1000 items. The endpoint is public with no auth middleware (consistent with existing public template reads); the global rate limiter is the only protection needed. Hints live in a dedicated `AgentPromptHint` table (id, text, published, sortOrder, timestamps), distinct from `AgentTemplate`, returning published rows ordered by `sortOrder`. The per-item 240-char cap and the 1000-item collection cap are enforced by the API, not the schema. The backend ships in a separate PR; until that endpoint is seeded and live, the app falls back to its cache or to an empty list, in which case the dice stays hidden.

### Metrics

The feature uses the existing metrics system. The canonical typed events live in the `convos-shared` SPM package, pinned by branch in `ConvosCore/Package.swift`; the merged change adds the API below, and the pin (and both `Package.resolved` files) were advanced to that revision.

- `built_agent` (existing event, fired on agent creation) gains `from_prompt_hint: Bool` and `tap_count: Int`, wired from `fromPromptHint` and `promptHintTapCount`.
- `prompt_hint_tapped` (new event) carries `tap_count: Int`, fired on each dice tap.

Wiring goes through the typed `CoreActions` methods (`builtAgent(..., fromPromptHint:tapCount:)` and `promptHintTapped(tapCount:)`), so there are no hand-rolled event strings on the app side. `NoOpCoreActions` was updated to the new protocol shape; the builder view model is the only `builtAgent` call site.

## Testing

- `ConvosCoreTests/PromptHintsServiceTests` -- service over the API client.
- `ConvosTests/PromptHintsModelTests` -- disk hydration, launch refetch, backoff retry loop (sleepless via the injected closure), last-good-cache survival on failure.
- `ConvosTests/AgentBuilderViewModelDiceTests` -- roll behavior, no-immediate-repeat, the three state fields, and visibility gating.

Live end-to-end QA needs the backend endpoint seeded on the local stack first: bring up the stack with `./dev/up`, apply backend migrations, then build and run the iOS worktree. Until the endpoint is live, the preview model and unit tests exercise the logic.

## Fast-follow: hints admin CRUD

Not in this PR. The curated list is seeded by a backend migration for v1; editing it later wants an admin surface:

- Backend first: agent-API-key-gated write endpoints on `convos-backend` (`POST /api/v2/agent-prompt-hints`, `PATCH /:id`, `DELETE /:id`, optional reorder).
- Then a thin Hono proxy in `convos-assistants` (alongside the existing `admin/templates`) that passes through to those endpoints, inheriting the parent admin router's auth, optionally with a static admin page. The proxy is inert until the backend write endpoints exist.

`convos-assistants` requires no changes to ship v1 -- it shares no database with `convos-backend` and the new table is inert to it.

## References

- Notion "Prompt Hints" spec -- problem, goals, and the canonical event definitions.
- `convos-backend` `feature/prompt-hints` -- the `AgentPromptHint` table, seed migration, and the public `GET /api/v2/agent-prompt-hints` endpoint (separate PR).
- `Convos/Agent Builder/AgentBuilderView.swift`, `AgentBuilderViewModel.swift`, `AgentDraftComposer.swift`, `PromptHintsModel.swift`, `PromptHintsService+Live.swift` -- the app-side surface.
- `ConvosCore/Sources/ConvosCore/Services/PromptHintsService.swift`, `API/ConvosAPIClient.swift` -- the service and API client.
- `agent-builder-flow-simplification.md` -- the direct (non-conversation) builder flow the composer lives in.
