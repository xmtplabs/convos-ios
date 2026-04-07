# Voice Memo Transcription

## Summary
Add on-device transcription for received voice memos. When a voice memo message is received and stored locally, the app should schedule a background transcription job using only local system capabilities. Once transcription completes, the messages UI should show a transcript cell directly beneath the related voice memo. The transcript cell should be expandable and collapsible, and should update automatically when the transcription becomes available.

## Goals
- Transcribe received voice memos locally without any server calls
- Start transcription asynchronously after the attachment is available locally
- Persist transcript results so they survive app relaunches
- Render transcript content as a distinct message-adjacent cell below the voice memo
- Support expandable/collapsible transcript UI
- Keep the voice memo experience responsive while transcription runs in the background

## Non-goals
- Cloud transcription
- Transcribing outgoing voice memos before send
- Editing transcript text
- Translation, summarization, or speaker diarization
- Re-transcribing non-audio attachments

## User experience
- A received voice memo appears normally
- After the audio is downloaded and local data is available, transcription starts in the background
- While transcription is pending, the app may show no transcript row or a lightweight "Transcribing…" row depending on implementation choice
- When the transcript is ready, a transcript cell appears directly beneath the voice memo bubble
- The transcript cell defaults to a compact collapsed state with a short preview
- Tapping the cell expands it to show the full transcript
- Tapping again collapses it
- Transcript state should feel local to the current device; it is not synced to other participants

## Product decisions to confirm
- Whether transcript rows should be shown for outgoing voice memos too, or only incoming ones
- Whether to show an explicit pending state vs only inserting the row after success
- Whether collapse/expand state should persist per message locally or reset each launch
- Whether failed transcription should be silently ignored or surfaced as a retry affordance

## Proposed architecture

### 1. Local transcription service
Add a new local-only transcription service in ConvosCore, for example:
- `VoiceMemoTranscriber`
- `VoiceMemoTranscriptionJobRunner`

Responsibilities:
- Accept a local audio file URL or raw audio data
- Run on-device transcription using Apple local frameworks only
- Return structured transcript output
- Avoid duplicate concurrent work for the same message or attachment key
- Support cancellation if the app no longer needs the work

Likely shape:
- `transcribe(messageId:attachmentKey:fileURL:) async -> VoiceMemoTranscriptResult`
- actor-backed deduplication similar to other local loaders

Implementation note:
- The exact Apple framework choice should be validated during implementation based on deployment target and availability. The plan assumes an on-device-only speech transcription API is available and acceptable for the project.

### 2. Persistent local transcript model
Add a local database table for transcript state keyed by message or attachment.

Suggested fields:
- `messageId` or `attachmentKey` as primary key
- `conversationId`
- `status` (`pending`, `completed`, `failed`)
- `text`
- `languageCode?`
- `errorDescription?`
- `createdAt`
- `updatedAt`

Optional fields:
- `segmentsJSON?` if future per-segment timing is desired
- `version` if transcript schema or engine changes later

This model should remain device-local and should not be sent over XMTP.

### 3. Scheduling transcription work
Transcription should begin after a received voice memo becomes locally available.

Natural trigger points:
- After `RemoteAttachmentLoader` downloads audio for playback
- Or during incoming message processing once a voice memo is detected and local caching is possible
- Or from a dedicated repository observer that sees a received audio attachment without a transcript

Recommended approach:
- Keep scheduling out of view code
- Trigger from a data/service layer that can observe newly available received audio attachments
- Deduplicate work so repeated message hydration or cell appearance does not start multiple jobs

A good pattern would be:
- detect received `audio/*` attachment
- enqueue local transcription if transcript record does not exist or is stale
- store `pending`
- run job in background task
- write `completed` or `failed`

### 4. Hydration and UI composition
Transcript content should not be a new XMTP message. It should be a local UI artifact attached to a voice memo message.

Recommended data flow:
- Extend the hydrated message/list model to optionally include a local transcript payload for voice memo items
- Messages list processing should emit an additional list item directly after a voice memo when transcript data exists
- This transcript list item should reference its parent message ID for grouping and updates

Possible new list item type:
- `.voiceMemoTranscript(VoiceMemoTranscriptListItem)`

Fields might include:
- `parentMessageId`
- `text`
- `status`
- `isExpanded`
- `isOutgoing`
- sender/date context if needed for layout rules

This keeps transcript rendering explicit and avoids overloading the existing attachment bubble.

### 5. Expand/collapse state
Because expand/collapse is purely presentation state, keep it local to the app.

Recommended options:
- Start with ephemeral UI state in the view model keyed by `messageId`
- If persistence is desired later, add a lightweight local preferences store keyed by message ID

The simplest initial version:
- transcript cell collapsed by default
- `ConversationViewModel` stores a `Set<String>` of expanded transcript parent message IDs
- tapping transcript toggles membership in that set
- message list rebuild uses this set to mark transcript rows expanded/collapsed

### 6. Rendering
Add a new SwiftUI cell/view for transcript rows, for example:
- `VoiceMemoTranscriptView`

Behavior:
- compact collapsed preview with line limit
- expanded full text with smooth animation
- clear visual connection to the parent voice memo but distinct from sender-authored messages
- should not look like a sent/received chat bubble written by the sender

Placement:
- directly beneath the parent voice memo item
- grouped visually with the memo but semantically distinct

### 7. Retry and failure behavior
For failures:
- store failed state locally
- avoid infinite retry loops
- consider retrying only on explicit user action or on app version/engine changes

For pending:
- if the app terminates mid-transcription, pending records can be resumed or retried on next launch

## Suggested implementation phases

### Phase 1: Data model and storage
- Add transcript table and migrator
- Add transcript model types and repository/writer interfaces
- Add tests for storing and reading transcript state

### Phase 2: On-device transcription service
- Implement local transcription service using Apple on-device APIs
- Add deduplication and background execution handling
- Add unit tests around job orchestration and duplicate suppression

### Phase 3: Triggering pipeline
- Detect received voice memos eligible for transcription
- Schedule background transcription once local audio is available
- Persist `pending`, `completed`, and `failed`

### Phase 4: Message list integration
- Add transcript-aware hydrated/list item models
- Insert transcript list items immediately below related voice memos
- Ensure list diffing and grouping remain stable

### Phase 5: UI
- Build transcript row view
- Add expand/collapse handling
- Tune spacing, hierarchy, and animation

### Phase 6: QA
- Receive voice memo
- Verify transcript appears later without blocking UI
- Verify transcript survives app relaunch
- Verify collapse/expand behavior
- Verify no transcript row for non-audio attachments
- Verify no network dependency

## Risks and considerations
- On-device speech APIs may have availability, entitlement, locale, or model-download constraints that need validation
- Background execution time may be limited if the app is suspended quickly after receipt
- Repeated hydration or redownload events could trigger duplicate work without careful deduplication
- Transcript cells must not interfere with existing message grouping, reply, context menu, or scroll behavior
- Local-only transcript data must be clearly separated from synced message content

## Open technical questions
- Which local Apple speech API is best for offline transcription on the app’s minimum OS target?
- Where is the cleanest place to observe "received voice memo now available locally" without putting job orchestration in view code?
- Should transcript rows appear only after local download, or should playback-triggered download be enough to kick off transcription?
- Should transcript generation happen only on Wi‑Fi/charging, or always when local audio is available?

## Recommendation
Proceed with a local-only architecture where transcript data is persisted in a dedicated local table and rendered as a distinct list item under each voice memo. Keep orchestration in ConvosCore, keep expand/collapse state in app-local view model state, and avoid treating transcripts as real messages.

## Implementation status

### Completed in this branch
- Transcript storage layer
  - `ConvosCore/Sources/ConvosCore/Storage/Models/VoiceMemoTranscript.swift`
  - `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBVoiceMemoTranscript.swift`
  - `ConvosCore/Sources/ConvosCore/Storage/Repositories/VoiceMemoTranscriptRepository.swift`
  - `ConvosCore/Sources/ConvosCore/Storage/Writers/VoiceMemoTranscriptWriter.swift`
  - new `voiceMemoTranscript` table migration in `SharedDatabaseMigrator.swift`
- Session plumbing
  - `voiceMemoTranscriptRepository()`, `voiceMemoTranscriptWriter()`, and `voiceMemoTranscriptionService()` on `SessionManagerProtocol`
  - real implementations on `SessionManager` (transcription service is cached lazily per session)
  - mock implementations on `MockInboxesService` and `MockRepositories.swift`
- Messages list integration
  - new `VoiceMemoTranscriptListItem` value type and `MessagesListItemType.voiceMemoTranscript` case
  - reuse identifier and alignment handling for the new case
  - `MessagesListRepository` accepts a transcript repository and a conversation id, observes transcripts, and injects transcript rows directly under each voice memo
  - local expand/collapse state tracked in `MessagesListRepository.expandedTranscriptMessageIds`
  - `setTranscriptExpanded(_:for:)` is exposed on `MessagesListRepositoryProtocol`
- Expand / collapse UI plumbing
  - `VoiceMemoTranscriptRow` now takes an `onToggleTranscript` callback, shows a chevron when a completed transcript is available, and toggles between compact (2-line) and full text
  - `CellConfig`, `MessagesCollectionViewDataSource`, `MessagesCollectionDataSource`, `MessagesListItemTypeCell`, `MessagesViewController`, `MessagesViewRepresentable`, `MessagesView`, and `ConversationView` all thread `onToggleTranscript` through
  - `ConversationViewModel.toggleTranscriptExpansion(for:)` flips the expanded state on the repository
- On-device transcription service
  - `ConvosCore/Sources/ConvosCore/Messaging/VoiceMemoTranscriber.swift` – actor that wraps `SpeechAnalyzer` + `SpeechTranscriber`, picks an on-device locale, downloads/installs speech assets via `AssetInventory.assetInstallationRequest`, and deduplicates per message id
  - `ConvosCore/Sources/ConvosCore/Messaging/VoiceMemoTranscriptionService.swift` – orchestrator that:
    - uses a `State` actor to reserve a slot per message id (prevents duplicate scheduling)
    - skips messages that already have any transcript row
    - marks `pending`, loads the encrypted audio via `RemoteAttachmentLoader`, writes it to a temporary file, runs the transcriber, and writes `completed` / `failed` via `VoiceMemoTranscriptWriter`
  - `Info.plist` key `NSSpeechRecognitionUsageDescription` added to the Convos Dev / Prod / Local build configurations
- Background triggering
  - `ConversationViewModel.scheduleVoiceMemoTranscriptionsIfNeeded(in:)` scans each messages-publisher emission and the initial fetch for incoming `audio/*` attachments, then calls the service on a detached `.utility` task
  - Outgoing voice memos are skipped

### UI scaffolding (from the previous step)
- new SwiftUI view `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/VoiceMemoTranscriptRow.swift`
- rendered from both rendering paths:
  - `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Cells/MessagesListItemTypeCell.swift`
  - `Convos/Conversation Detail/Messages/MessagesListView/MessagesListView.swift`
- estimated layout heights handled in `DefaultMessagesLayoutDelegate.swift`

### Failure / retry path
- `VoiceMemoTranscriptionServicing.retry(...)` bypasses the "already has a transcript" guard.
- `VoiceMemoTranscriptionService` still skips failed transcripts on a normal `enqueueIfNeeded` (so we don't loop), but a user-initiated retry forces the job through.
- `VoiceMemoTranscriptListItem` now carries `mimeType` and `errorDescription`. The transcript row renders the error description as a small subdued line and a `Try again` capsule button when `status == .failed`. The button is wired through `CellConfig.onRetryTranscript` → data source → view controller → `MessagesViewRepresentable` → `MessagesView` → `ConversationView` → `ConversationViewModel.retryTranscript(for:)`.
- `LoadedAttachment` gained an explicit `public init` so tests and other modules can construct one.

### Persistence of expand/collapse
- New helper `Convos/Conversation Detail/Messages/MessagesListView/VoiceMemoTranscriptExpansionStore.swift` stores the set of expanded message ids in `UserDefaults`, keyed by `VoiceMemoTranscriptExpansionStore.<conversationId>`.
- `MessagesListRepository` loads the set on init and writes it back on every toggle.

### Tests
- `ConvosCore/Tests/ConvosCoreTests/VoiceMemoTranscriptStorageTests.swift` exercises the writer/repository round-trip via an in-memory `MockDatabaseManager`. Covers: `markPending`, `saveCompleted` preserves `createdAt`, `saveFailed` records the error and keeps `createdAt`, and per-conversation scoping. A small `seedConversationStub` helper inserts the minimum non-null columns of `conversation` so the FK on `voiceMemoTranscript.conversationId` is satisfied.
- `ConvosCore/Tests/ConvosCoreTests/VoiceMemoTranscriptionServiceTests.swift` exercises the orchestration layer with stub actors for the transcriber, attachment loader, repository, and writer. Covers:
  - happy path writes pending then completed
  - existing completed transcript causes early return without invoking the transcriber or loader
  - existing failed transcript is not auto-retried by `enqueueIfNeeded`
  - explicit `retry(...)` bypasses the failed-skip and re-runs the transcriber
  - transcriber failure path writes via `saveFailed`
  - attachment loader failure path writes via `saveFailed` without invoking the transcriber
  - two concurrent `enqueueIfNeeded` calls for the same message id deduplicate to a single run
- All 11 new tests pass under `xcodebuild test -scheme ConvosCore`.

### QA scenario
- `qa/tests/32-voice-memo-transcription.md` registered in `qa/SKILL.md`. Exercises:
  - receiving a voice memo and waiting for the transcript row
  - tap to expand / tap to collapse
  - persistence of the expanded state across an app relaunch
  - no transcript row for non-audio attachments (photos)
  - no transcript row for outgoing voice memos
  - optional failure / retry affordance (best-effort, environment dependent)
- The test uses `say` on macOS to generate a small spoken-English `.m4a` payload that the on-device transcriber should handle reliably.

## Next implementation steps

### Step A — expand/collapse plumbing ✅
Done. Tapping a completed transcript row toggles between the 2-line preview and the full transcript. State lives in-memory on the `MessagesListRepository` and is not yet persisted across relaunches.

### Step B — local on-device transcription service ✅
Done. `VoiceMemoTranscriber` runs `SpeechAnalyzer` + `SpeechTranscriber` against a temp file written from the decrypted attachment data. `VoiceMemoTranscriptionService` is the orchestration layer that deduplicates, checks the repository, and calls the writer at the right lifecycle points. Authorization (`NSSpeechRecognitionUsageDescription`) is now declared in the Convos app build configurations.

### Step C — background triggering ✅ (initial version)
Done at the view-model level: `ConversationViewModel` observes the messages publisher and triggers transcription for incoming audio attachments on open and on every update. This satisfies the "transcription happens without user interaction" goal for foregrounded conversations. A truly background path (e.g. when the app receives a voice memo push notification while suspended) is still out of scope.

### Step D — UX polish ✅
Done. Failed transcripts now show an inline error description and a `Try again` capsule button. Tapping it calls `VoiceMemoTranscriptionService.retry(...)`, which bypasses the "already failed" skip. Expand/collapse state persists across launches via `VoiceMemoTranscriptExpansionStore` (UserDefaults, keyed per conversation).

Still optional / not pursued:
- Smarter scroll-to-bottom behavior when a transcript first arrives and pushes content off screen.
- Custom failure copy per `VoiceMemoTranscriberError` case (currently we surface `localizedDescription`, which is already user-friendly enough).

### Step E — QA ✅
Done.
- `ConvosCore/Tests/ConvosCoreTests/VoiceMemoTranscriptStorageTests.swift` (4 tests) and `ConvosCore/Tests/ConvosCoreTests/VoiceMemoTranscriptionServiceTests.swift` (7 tests) all pass under `xcodebuild test -scheme ConvosCore`.
- `qa/tests/32-voice-memo-transcription.md` written and registered in `qa/SKILL.md`.

## Branch state
- Branch: `jarod/voice-memo-transcription-plan`
- Build: succeeds against `Convos (Dev)` simulator scheme on `convos-jarod-voice-memo-transcription-plan`
- Tests: 11 new unit tests pass; existing tests untouched
- Lint: `swiftlint lint --strict` reports 0 violations across 500 files
- Manual smoke test: app launches on the simulator without crashes
- Remaining work: live QA execution of `qa/tests/32-voice-memo-transcription.md` once a real device or simulator with the on-device speech model installed is available
