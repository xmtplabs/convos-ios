# Agent Builder Flow Simplification — Phase 3 detail

Phase 3 = **media inputs** for the direct builder: let a build carry images,
photos, voice notes (and, essentially for free, PDFs) alongside the text
prompt, uploaded through the agent-templates presigned endpoint and referenced
in `inputs.attachments[]` on the generation request.

Context and earlier phases live in `agent-builder-flow-simplification.md`; the
text/home groundwork is in `-phase-1.md`; the progress/preview cards are in
`-phase-2.md`. The full backend contract is checked in at
`docs/plans/agent-generation-api.openapi.yaml`.

**Status: planned.** Depends on backend PR **#310** (CON-533) being deployed
to Dev. Connections (`connections[]`, PR #311) are explicitly Phase 4, not
here.

## Scope

In scope: still images (photo library), camera photos, and voice notes. These
mirror what the legacy builder composer surfaces, and all three are accepted by
the generation API.

Out of scope (this chunk):

- **PDF / files.** The generation API accepts `application/pdf`, and the legacy
  composer has the file-picker plumbing (`fileImporter`, `stageFile`, 20 MB
  cap) we could reuse. But PDF isn't a priority surface right now, so we don't
  enable it here — mirror the legacy decision and leave the file path alone.
  Easy to add later by reusing that plumbing + the same upload path.
- **Video.** The generation attachment allowlist has no video MIME type, so the
  direct flow cannot send video to the builder. The composer must hide / reject
  video for direct builds (the legacy flow allowed it).
- **Connections.** Deferred to Phase 4.
- **Encryption.** Generation attachments are uploaded as plaintext (see below);
  there is no XMTP attachment crypto in this path.

## Key correction — these are not XMTP RemoteAttachments

The app's existing media pipeline produces an XMTP `RemoteAttachment`: it
encrypts the bytes with `RemoteAttachment.encodeEncrypted(content:codec:)`,
uploads the ciphertext to `v2/attachments/presigned` (public-read,
`application/octet-stream`), and ships the `secret`/`salt`/`nonce`/`url` inside
a message so the recipient can fetch and decrypt. That is the right shape for a
message to a peer.

The generation API wants something different and simpler. Per PR #310 the
backend reads the bytes itself (for generation + moderation), so:

- Attachments go to a **separate** endpoint:
  `GET /v2/agent-templates/attachments/presigned?contentType=…`, which returns
  `{ objectKey, uploadUrl }` — **no `assetUrl`** (private bucket, nothing public
  is minted).
- The client `PUT`s the **raw, unencrypted** bytes to `uploadUrl` with the real
  `Content-Type` (e.g. `image/jpeg`), not octet-stream.
- The generation request carries an `AttachmentRef { objectKey, mimeType,
  filename? }` per file in `inputs.attachments[]`. The backend resolves the
  object key to bytes server-side.

So we do **not** call `RemoteAttachment.encodeEncrypted`, and we do **not**
build any XMTP content type for this flow. "Leave it unencrypted" is the whole
point: the agent isn't in a conversation with us yet, so there's no shared
secret and no message — just plaintext bytes the backend ingests by key.

What we reuse vs. build new:

| Reuse (already in the app) | Build new (Phase 3) |
| --- | --- |
| Image acquisition + compression (`ImageCompression.compressForPhotoAttachment`, photo library / camera pickers) | `ConvosAPI.AttachmentRef` model + `Inputs.attachments` field |
| `VoiceMemoRecorder` (m4a, 44.1 kHz, ≤ 5 min) and its chip/levels UI | API client: `agent-templates/attachments/presigned` GET + a plaintext `PUT` upload |
| Builder composer attachment staging (`pendingMediaAttachments`, `recordedVoiceMemo`); the existing eager-upload pattern for messages | Eager per-attachment upload (local file -> object key) tracked on the pending attachment |
| Prompt card attachment rendering (`AgentBuilderSummary` already models attachments) | `DBAgentTemplateGeneration` attachment columns + persistence (at Make) |
| | Client-side caps / MIME validation + 400/422 mapping |

## Backend contract (PR #310)

Presigned mint — `GET /v2/agent-templates/attachments/presigned`:

- Query `contentType` (required, allowlisted) **and `contentLength`** (required,
  positive — the exact byte count of the upload). The OpenAPI doc only listed
  `contentType`, but the deployed endpoint rejects a missing/zero
  `contentLength` with `400 {"error":"contentType and a positive contentLength
  are required"}` — verified live on Dev.
- `200` -> `{ objectKey, uploadUrl }` with `Cache-Control: no-store`. Per-IP
  rate limited. `400` unsupported `contentType` / missing `contentLength`; `503`
  uploads not configured for the environment.
- Then `PUT` the bytes to `uploadUrl` with the same `Content-Type`. Because
  `contentLength` is baked into the presigned URL, the upload sequence must be:
  **produce the final bytes first** (compress the image / finalize the audio) ->
  mint with that exact length -> `PUT` exactly those bytes. Re-compressing after
  minting would change the size and the `PUT` would be rejected.

Generation request — `inputs.attachments[]`:

- `AttachmentRef { objectKey (1..512), mimeType (allowlist), filename? }`.
- `maxItems: 9`; aggregate **60 MB** across all attachments; the whole request
  body is capped at **40 MB** (`413`).
- Per-kind size caps and allowlist:
  - **image**: `image/png`, `image/jpeg` — ≤ 5 MB.
  - **pdf**: `application/pdf` — ≤ 25 MB.
  - **audio**: `audio/mp4`, `audio/m4a`, `audio/x-m4a`, `audio/aac`,
    `audio/mpeg`, `audio/wav`, `audio/x-wav`, `audio/ogg`, `audio/webm` —
    ≤ 25 MB; **transcribed to text** before generation.
- `inputs` must still have `text` and/or at least one attachment.
- Auth: anonymous is allowed, but we send the bearer JWT (attributes the
  generation to the account, as today).

Idempotency interaction (important): the request body — including the
attachment object keys — is part of the idempotency comparison. Reusing the
same `Idempotency-Key` with different object keys returns `409`. This drives the
persistence/resume design below.

## Source -> upload mapping

| Composer source | App type | Upload MIME | Client cap before upload | Notes |
| --- | --- | --- | --- | --- |
| Photo library | `PendingPhotoAttachment.image: UIImage` | `image/jpeg` | compress to ≤ 5 MB | reuse `compressForPhotoAttachment`; JPEG is in the allowlist |
| Camera photo | `PendingPhotoAttachment.image: UIImage` | `image/jpeg` | compress to ≤ 5 MB | same path as library photos |
| Voice note | builder VM `recordedVoiceMemo` (m4a file) | `audio/m4a` (or `audio/wav` if we transcode) | recorder already ≤ 5 min (~2–3 MB at 64 kbps) | backend transcribes to text; **m4a path unverified — see audio-format risk** |
| PDF / files | `PendingFileAttachment` | (`application/pdf`) | — | **deferred** — not enabled this chunk; plumbing exists to add later |
| Video | `PendingVideoAttachment` | — | n/a | **not supported by the API** — hide/reject for direct builds |

Total count must be ≤ 9 and aggregate ≤ 60 MB; enforce both client-side and
surface a friendly message rather than relying on the server `400`. (The 40 MB
body `413` is effectively moot — the bytes never ride the generation body, only
object-key refs do.)

## Data layer

API model (`ConvosCore/.../API/AgentTemplateGenerationModels.swift`):

- New `ConvosAPI.AttachmentRef: Codable { objectKey: String; mimeType: String;
  filename: String? }`.
- `AgentTemplateGenerationRequest.Inputs` += `attachments: [AttachmentRef]?`
  (omit/`nil` when empty so text-only requests are unchanged).

API client (`ConvosAPIClient` + protocol + `MockAPIClient` + test stub):

- `func getAgentTemplateAttachmentPresignedURL(contentType: String) async throws
  -> (objectKey: String, uploadURL: String)` hitting
  `v2/agent-templates/attachments/presigned`. Authenticated (JWT) like the
  generation calls; decode `{ objectKey, uploadUrl }`. This is a **new** method
  — the existing `getPresignedUploadURL` targets `v2/attachments/presigned`,
  returns an `assetUrl`, and is wired for the encrypted message path; do not
  reuse it.
- `func uploadGenerationAttachment(data: Data, contentType: String, to
  uploadURL: String) async throws` — a plain `PUT` of the raw bytes with the
  given `Content-Type`. (Mirror the existing S3 `PUT` mechanics but without the
  octet-stream/encrypted assumptions.)
- `createAgentTemplateGeneration(...)` gains an `attachments: [AttachmentRef]`
  parameter, threaded into the request body's `inputs.attachments`.

Persistence (`DBAgentTemplateGeneration` + an additive, nullable migration):

- Add an `attachments` column: JSON-encoded array of
  `{ localPath, mimeType, filename, objectKey? }`. At Make, the resolved object
  keys (uploaded eagerly while composing) plus a stable local copy of each file
  are persisted on the row.
- Rationale: a post-Make build must survive backgrounding/relaunch (consistent
  with Phases 1–2). Persisting the minted keys lets an in-TTL resume reuse them
  and keep the idempotency body stable; persisting the local copy lets a resume
  re-upload if the object keys have expired.

## Upload timing — in the repository, after Make (implemented)

Intended eager-while-composing upload, but the composer's photos live in the
inner `ConversationViewModel` (keyed by ids the builder VM doesn't own, and it
already runs a separate message-eager-upload). True upload-on-add would mean
surgery on `ConversationViewModel` + id correlation for removals. Instead, the
implemented flow uploads inside the repository right after the row is created,
which keeps all attachment state in the repo's state machine and shows the
Phase 2 card immediately:

1. At Make, `AgentBuilderViewModel` gathers staged photos, compresses each to
   JPEG (`ImageCompression.compressForPhotoAttachment`, ~1 MB, well under the
   5 MB cap), and hands the bytes to `startGeneration(..., attachments:)` as
   `AgentBuildAttachmentInput`s.
2. `startGeneration` writes each file to a per-generation temp dir, persists the
   row (`status = submitting`) with `[StoredGenerationAttachment]` (object keys
   nil), so the activating card shows instantly.
3. The repo pipeline runs an **upload step before submit**: for each attachment,
   mint a presigned URL with the exact byte count, `PUT` the bytes, persist the
   returned `objectKey`. Failure marks the build `failed`; the temp dir is
   cleaned up on `invited`/`failed`.
4. `submit` includes the resolved `AttachmentRef`s in the POST.

The upload window is covered by the card's `preparing` phase. True
upload-on-add (snappier Make) remains a possible follow-up via inner-VM changes.

Eager-upload housekeeping:

- **Removing an attachment** before Make: its uploaded object is simply
  abandoned (the backend's private-bucket TTL reaps unreferenced build objects);
  cancel the in-flight upload if still running.
- **Abandoning the build** (never tapping Make): same — uploaded objects are
  orphaned and TTL-reaped. Pre-Make composer state is not persisted (consistent
  with the composer being ephemeral); only Make writes the build row.
- **The `preparing` window**: because uploads usually finish during composition,
  Make is normally instant. If an upload is still in flight, the Phase 2
  activating card sits in its `preparing` phase ("uploading") until keys
  resolve, rather than blocking the tap.

Resume / idempotency edges:

- On resume of a persisted build, reuse the persisted `objectKey`s so the
  idempotency body is identical.
- If the POST returns `400` for a stale/expired object key, treat it as a fresh
  build: re-upload from the persisted local copies and derive a **new**
  idempotency key (fold the object keys into the deterministic key so new keys
  naturally produce a new idempotency key).
- Clean up the generation's stable directory on terminal `done`/`failed`.

## UI / composer

The direct builder already stages everything we need — it routes photos
through the inner `ConversationViewModel.pendingMediaAttachments`
(`addPhotoAttachment` / `removeAttachment`) and holds `recordedVoiceMemo` +
levels for the voice note. Phase 3 wiring:

- Surface only **photo library, camera, and voice** for direct builds —
  matching the legacy builder composer. Leave the file/PDF picker and video out
  (the file plumbing stays but isn't enabled; the API has no video MIME).
- As each photo / voice note is added, start its eager upload (see upload-timing
  section) and track the resulting `objectKey` on the pending attachment.
- On Make (`startDirectGeneration`), gather the pending photos and the recorded
  voice note's resolved object keys and hand them to `startGeneration`.
- Populate `AgentBuilderSummary.attachments` so the preserved creation-prompt
  card (Phase 2) renders the attachment chips for the build — the summary model
  and `AgentBuilderSummaryView` already support photo/voice chips; Phase 1 left
  them empty.
- Client-side validation: per-kind size caps, ≤ 9 items, ≤ 60 MB aggregate
  (the composer already caps at 8 pending attachments). Surface a friendly
  message when exceeded.

Voice-note note: the messages composer sends a voice memo immediately, but the
builder VM already *stages* `recordedVoiceMemo` rather than sending it, so the
direct flow uploads it eagerly and picks it up at Make like a photo — no new
staging type needed.

## Error handling

Map the generation responses to friendly composer states:

- `400` bad/over-cap/**unfetchable** attachment or unknown field -> "Couldn't
  use one of your attachments." The backend validates object keys at submit
  (HEAD + size/type), so a stale/expired key returns `400`; prefer catching
  size/count/MIME client-side so this is rare.
- `413` body > 40 MB -> effectively unreachable now (bytes aren't in the body);
  the 60 MB aggregate guard is the real cap. Handle defensively, don't design
  the UX around it.
- **Partial upload failure** (one of several attachments fails to upload): block
  Make with a retry affordance rather than silently dropping the attachment;
  re-upload reuses the local copy.
- `422` moderation at submit -> reuse the existing moderation-blocked surface
  from Phase 1.
- **Image moderation during the run**: #310 added Rekognition image moderation
  in the executor, so a build with an image can land in terminal `status:
  failed` (not a submit-time `422`). The poll loop's `failed` handling must
  cover this and surface a moderation-flavored message, not a generic error.
- Presigned `503` (uploads not configured) -> treat as a transient build
  failure with a retry affordance; log clearly so it's obvious the environment
  lacks upload config. The presigned endpoint is rate limited (20 req/min per
  IP) — fine for <= 9 files per build, but back off rather than hammering.

## Audio-format risk (voice notes)

The app records **m4a** (`VoiceMemoRecorder`, AAC in an MP4 container). PR #310's
author explicitly flags that OpenRouter's audio input is reliable for **wav/mp3**
but the **m4a container is unverified** ("needs a live smoke test — if the model
rejects the container it's a server-side transcode or an STT-provider swap").
The early prior-notes "wav uploader" line points the same direction.

Plan: **smoke-test the m4a path end-to-end first.** If the backend transcribes
m4a reliably, upload `audio/m4a` as-is (simplest). If it doesn't, transcode the
recorded memo to **wav** client-side before upload (`audio/wav` is in the
allowlist and is the reliable format) — a small AVFoundation export step. Decide
this with a live test rather than guessing; don't ship voice notes until the
chosen format round-trips to a transcript.

## Open questions / decisions

Resolved:

- **Scope**: image (library) + camera + voice this chunk. PDF deferred; video
  unsupported.
- **Upload timing**: eager, while composing.

Still open:

- **HEIC / PNG**: library/camera images can be HEIC; compress to JPEG (in the
  allowlist) by default. Keep PNG only if a source is already PNG and under cap;
  otherwise normalize to JPEG.
- **Idempotency-key derivation**: fold the object keys into the deterministic
  key so re-uploads can't silently collide with a prior body.
- **Audio format (m4a vs wav)**: resolve via the smoke test in the audio-format
  risk section above before shipping voice notes.
- **`estimatedDurationMs`**: #310 returns it on non-terminal polls (larger when
  attachments are present). Consider modeling it to pace the Phase 2 activating
  card's progress bar instead of the fixed client estimate.

## Acceptance checks

1. Attaching a photo (library or camera) + typing a prompt, then Make: the
   photo is uploaded eagerly during composition, the generation POST carries the
   right `attachments[]` object key, and the build completes and joins as in
   Phases 1–2.
2. A voice note alone (no text) produces a valid build (backend transcribes it).
3. Video is not offered in the direct composer.
4. Over-cap / too-many attachments are blocked before upload, not via a server
   `400`.
5. A partial upload failure blocks Make with a retry, not a silently-dropped
   attachment.
6. The creation-prompt card shows the attachment chips for the build.
7. Backgrounding/relaunch mid-build (after Make) preserves the attachments and
   the build resumes (reusing object keys, re-uploading only if expired).
8. No regression to text-only builds or to the legacy maker (flag off).

## Out of scope (later)

- PDF / file attachments (plumbing exists; not enabled this chunk).
- `connections[]` + `GET /connections/services` (PR #311) — Phase 4.
- Richer attachment previews; relaxing the prompt-card 180s lifetime;
  networking the prompt card to other members.
