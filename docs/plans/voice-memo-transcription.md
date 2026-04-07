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
  - `voiceMemoTranscriptRepository()` and `voiceMemoTranscriptWriter()` added to `SessionManagerProtocol`
  - real implementations on `SessionManager`
  - mock implementations on `MockInboxesService` and `MockRepositories.swift`
- Messages list integration
  - new `VoiceMemoTranscriptListItem` value type and `MessagesListItemType.voiceMemoTranscript` case
  - reuse identifier and alignment handling for the new case
  - `MessagesListRepository` now accepts a transcript repository and a conversation id, observes transcripts, and injects transcript rows directly under each voice memo
  - basic local expand/collapse state tracked in `MessagesListRepository.expandedTranscriptMessageIds`
- UI scaffolding
  - new SwiftUI view `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/VoiceMemoTranscriptRow.swift`
  - rendered from both rendering paths:
    - `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Cells/MessagesListItemTypeCell.swift`
    - `Convos/Conversation Detail/Messages/MessagesListView/MessagesListView.swift`
  - estimated layout heights handled in `DefaultMessagesLayoutDelegate.swift`

### Not yet wired
- Tap-to-expand path
  - `VoiceMemoTranscriptRow` does not yet receive an action callback
  - `MessagesListItemTypeCell` and `MessagesListView` do not yet thread an `onToggleTranscript` callback
  - `ConversationViewModel` does not yet expose a method that calls `MessagesListRepository.setTranscriptExpanded(_:for:)`
- Local transcription service
  - no `VoiceMemoTranscriber` exists yet
  - no on-device Apple speech integration yet
  - no background scheduling that observes received voice memos and triggers transcription
  - no orchestration that calls `VoiceMemoTranscriptWriter.markPending` / `saveCompleted` / `saveFailed`
- QA / tests
  - no unit tests for the storage layer yet
  - no QA scenario file yet

## Next implementation steps

### Step A — expand/collapse plumbing
Goal: tapping a transcript row toggles between collapsed preview and full text without losing local state.

Suggested edits:
- Add an `onToggleTranscript: (String) -> Void` to:
  - `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/VoiceMemoTranscriptRow.swift`
  - `CellConfig` in `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Data Source/CellFactory.swift`
  - `MessagesListView.swift`
  - the conversation rendering path that builds `CellConfig`
- Expose a method on `ConversationViewModel`:
  - `func toggleTranscriptExpansion(for messageId: String)`
  - which calls `messagesListRepository.setTranscriptExpanded(...)`
- Apply a tap gesture or button in `VoiceMemoTranscriptRow` that calls the toggle.

### Step B — local on-device transcription service
Goal: receive voice memo → transcribe locally → persist transcript record → list updates automatically via existing publisher path.

Suggested shape:
- New file `ConvosCore/Sources/ConvosCore/Messaging/VoiceMemoTranscriber.swift`
  - `public actor VoiceMemoTranscriber`
  - `func transcribe(messageId: String, conversationId: String, attachmentKey: String, fileURL: URL) async throws -> String`
  - deduplicate by `messageId`
  - support cancellation
- Use Apple’s on-device speech transcription API. Validate availability against the deployment target during implementation.
- Wrap calls in a small orchestration type, for example `VoiceMemoTranscriptionService`, that:
  - exposes `enqueueIfNeeded(message:)`
  - uses the `VoiceMemoTranscriptRepository` to skip already-transcribed messages
  - calls `VoiceMemoTranscriptWriter.markPending` before starting
  - calls `saveCompleted` or `saveFailed` when done

### Step C — background triggering
Goal: when a received voice memo becomes locally available, transcription runs without user interaction.

Suggested integration points:
- Hook in after the existing remote attachment hydration path so the orchestrator is notified of new locally available audio attachments
- Skip transcription for outgoing voice memos unless explicitly enabled
- Avoid duplicate work via the writer/repository check
- Run inside a `Task` that respects app lifecycle and cancellation

### Step D — UX polish
- Clear collapsed/expanded transitions
- Failure state affordance
- Optional persistence of expand/collapse across launches
- Optional retry button on failed transcripts

### Step E — QA
- new QA scenario file `qa/tests/32-voice-memo-transcription.md`
- exercise:
  - receiving a voice memo
  - transcript appearing later
  - expanding and collapsing
  - persistence across relaunch
  - no transcript row for non-audio attachments

## Branch state
- Branch: `jarod/voice-memo-transcription-plan`
- Build: succeeds against `Convos (Dev)` simulator scheme
- Storage and list integration are landed but the UI is read-only and the transcription service is not yet implemented
