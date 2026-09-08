# Backend Profiles: One Profile Per Person

**Status:** phase 1 shipped; agent parity shipped · **Repos:** convos-ios, convos-assistants (`backend/`, herald-lite), convos-cli

> The backend moved. `xmtplabs/convos-backend` was marked deprecated on
> 2026-08-12 and the service now lives at `convos-assistants/backend/` — same
> Express + Prisma codebase, same `src/api/v2` layout. Build there; the old repo
> is historical.

## Problem

A person's name and photo are, conceptually, one row. Today they are stored, merged, and
transported by **four systems running in parallel**, all of them per-conversation:

| System | Where it lives | What it does |
|---|---|---|
| `ConversationProfile` in group `appData` | `ConvosAppData/Proto/conversation_custom_metadata.proto` | One profile entry per member per group, inside the 8 KB MLS metadata blob |
| `ProfileUpdate` / `ProfileSnapshot` messages | `ConvosCore/Profiles/ProfileMessages/` | Custom content types carrying the same data as messages |
| Legacy `DBMemberProfile` | `Storage/Database Models/DBMemberProfile.swift` | The `(conversationId, inboxId)` table the UI actually renders from — 344 references |
| Canonical `DBProfile` + `DBProfileAvatar` | `ConvosCore/Profiles/Repository/` | The "unified profile" store: built, seeded, publishing — **but no view reads it yet** |

Everything downstream of that shape is complexity that exists only because the shape is wrong:

- **Fan-out is a per-conversation encryption job.** `MessagingProfilePublishSession.sendProfileUpdate`
  does this *for every conversation you are in*: fetch/ensure that group's `imageEncryptionKey` →
  re-encrypt your avatar with that key → upload a distinct ciphertext → send a `ProfileUpdate` →
  **and then take an MLS commit** to mirror the same profile into the group's `appData`. Change your
  photo in 30 conversations and that is 30 encryptions, 30 uploads, 30 messages, and 30 metadata
  commits of the same picture.
- **A durable job queue exists to survive that job.** `ProfilePublisher` (476 LOC) + `ProfilePublishStore`
  (351 LOC) + `DBProfilePublishJob` + `DBProfileAvatarSource` implement claim/stall-reclaim, exponential
  backoff with jitter, source versioning, and stale-batch supersede checks — machinery whose only reason
  to exist is that publishing a profile is expensive and per-conversation.
- **Inbound has to merge four sources.** `ProfileSource` ranks `contact < appData < profileSnapshot <
  profileUpdate`, and `ProfileMerge` resolves precedence × recency × tri-state avatar, per conversation.
  The same person updating their photo lands as N events across N conversations, each of which can
  arrive out of order, in the app or in the NSE.
- **`ProfileSnapshot` exists only to paper over MLS forward secrecy.** A new joiner cannot decrypt old
  `ProfileUpdate`s, so whoever adds them re-broadcasts everyone's profile — plus
  `PostPairProfileSnapshotBroadcaster` for the paired-device case.
- **Avatars are encrypted per group** (`ImageEncryption`, `EncryptedImageLoader`,
  `EncryptedImageService`, `EncryptedImagePrefetcher`, salt/nonce/key on every row and every wire
  message) — protecting a display picture the user chose in order to be recognized, at the cost of
  no CDN caching, no plain `URL` rendering, and a bespoke decrypt-and-cache path in every avatar view.
  It also forces the "public preview" path to *decrypt and re-upload the same image unencrypted*.
- **`UnifiedProfile` still carries `avatars: [String: Avatar]`** — a map keyed by conversation, with a
  "most recently updated slot wins" fallback, because even the canonical store inherited the assumption
  that you have a different face in every room.

All of it is residue from the old per-conversation-identity model (ADR 011 removed the per-conversation
*inbox*; the per-conversation *profile* survived it).

## Solution

**Storage moves to the Convos backend. XMTP keeps the change signal. The client keeps one row per person.**

```
     ┌────────────────────────────────────────────────────────────────┐
     │  1. WRITE (source of truth)                                    │
     │     iOS ──PUT /v2/profiles/me {name, avatarUrl}──▶ backend     │
     │     photo ──presigned PUT──▶ S3/CDN (plain, unguessable key)   │
     └───────────────────────────┬────────────────────────────────────┘
                                 │ on 200
     ┌───────────────────────────▼────────────────────────────────────┐
     │  2. SIGNAL (fan-out, unchanged rails)                          │
     │     ProfileUpdate v2 → every conversation I'm in               │
     │     {name, avatar_url, version} — no upload, no encryption,    │
     │     no metadata commit. Sender inbox is implicit ⇒ unspoofable │
     └───────────────────────────┬────────────────────────────────────┘
                                 │
     ┌───────────────────────────▼────────────────────────────────────┐
     │  3. READ (each client)                                         │
     │     profile(inboxId PK) — ONE row per person, no conversation  │
     │     miss / stale / never-received ──▶ POST /v2/profiles/batch  │
     │     avatar ──▶ plain URL through the normal image cache        │
     └────────────────────────────────────────────────────────────────┘
```

The signal is a *latency optimization*, not the transport. Because the backend can always answer
"who is `0xabc…`?", the pull path covers every gap the push path leaves — which is what lets
`ProfileSnapshot`, the publish queue, the appData mirror, and the four-source merge all be deleted
rather than reimplemented.

### The identity binding that makes this safe

The SIWE key **is** the XMTP identity key (`SIWESigner` signs with
`KeychainIdentity.keys.privateKey`, the same key that owns the inbox; `DeviceIdentitySnapshot`
reads `ethAddress`, `accountId`, and `inboxId` off the same record). So an authenticated account can
*prove* which inbox it is, and the backend can refuse any other claim:

1. Client `PUT`s its profile with its `inboxId`.
2. Backend resolves the account's SIWE address (`AuthMethod.externalKey`, type `SIWE`) → inbox id and
   caches it on `Account.inboxId`. `@xmtp/node-sdk` is already a dependency and exports both
   `getInboxIdForIdentifier(identifier, env)` (network lookup — authoritative, use this) and
   `generateInboxId(identifier)` (deterministic derivation — offline fallback).
3. Mismatch ⇒ `403`. One account, one inbox, one profile row — and no client can register a name or
   photo for someone else's inbox.

Paired devices share the identity private key (`LivePairingService` transfers
`identity.keys.privateKey.secp256K1.bytes`), so they resolve to the same address, the same account,
and the same profile — profile sync between paired devices becomes a non-event.

## Backend design (convos-assistants/backend)

### Schema

```prisma
model Profile {
  accountId String   @id @db.Uuid          // 1:1 with Account, per the "keyed by account" requirement
  inboxId   String   @unique                // the resolvable key — what clients actually hold
  name      String?  @db.VarChar(80)
  avatarUrl String?                         // absolute CDN URL, host-validated on write
  version   Int      @default(1)            // monotonic; rides the XMTP signal for cheap staleness checks
  updatedAt DateTime @updatedAt
  account   Account  @relation(fields: [accountId], references: [id], onDelete: Cascade)
}
```

Plus `Account.inboxId String? @unique` as the verified binding (written once, on first profile write
or auth, from the network lookup — never from a request body).

### Endpoints (all under the existing JWT + AppCheck middleware)

| Method | Path | Purpose |
|---|---|---|
| `PUT` | `/v2/profiles/me` | `{name?, avatarUrl?}` → full profile. Idempotent, bumps `version`. Explicit `null` clears. |
| `GET` | `/v2/profiles/me` | Self-restore on a fresh install or new paired device. |
| `GET` | `/v2/profiles/:inboxId` | Single lookup (invite previews, deep links). |
| `POST` | `/v2/profiles/batch` | `{inboxIds: [...]}` ≤ 100 → array. The workhorse: member lists, message authors, NSE. |

`ETag` / `If-None-Match` on reads so revalidation is a 304. Batch responses include `updatedAt` and
`version` so the client can skip writes.

**Agents resolve differently, because agent identity is no longer a database row.** There is no
`templateId` to join on: `AgentInstance` does not carry one, and agents are no longer created from a
gallery template as a matter of course — a caller with no template gets a synthesized default one.

What does exist is better. The assistants Worker computes the agent's identity at join time in
`buildJoinIdentity`: `name` from `template.agentName ?? params.name`, and the avatar from
`template.avatarUrl ?? params.profileImage`. At that moment it holds the agent's `inboxId`, its name,
and its avatar URL together. Herald then carries them onto XMTP — the name and attestation on a
`ProfileUpdate`, the avatar as `profile.imageURL` inside the `JoinRequest`.

Two consequences:

- **Agent avatars are already plain URLs.** They never went through the per-group encryption path, so
  there is nothing to unwind for them — they slot into the new model as-is.
- **Registration is a call, not a join.** The Worker should register the agent's profile with the
  backend at the same step it builds the join identity, using the agent API key it already holds
  exclusively (`agentApiKeyAuth`). One call, with data it already has in hand.

**Shipped as:** a separate `AgentProfile { inboxId @id, name, avatarUrl, version, updatedAt }` written
by `POST /v2/profiles/agent` under agent-API-key auth, with the read path resolving `Profile` first and
falling back to `AgentProfile`. Keeping it a second table is deliberate — folding agents into
`Profile` would mean a nullable `accountId` and two different auth paths writing one table, which
dissolves exactly the invariant (one account, one SIWE-bound inbox, self-authored only) that makes the
human path safe to expose. Two tables, two clearly different trust stories, one read surface.

Two guards came out of building it:

- **The endpoint refuses an inbox id already claimed by a person** (409). A collision is never written,
  so the read path's precedence never has to resolve one after the fact.
- **`proxyConvos` now denies `/api/v2/profiles`.** That forwarder injects the real agent key for
  *arbitrary* backend paths on behalf of the agent container — only `/api/v2/composio` and
  `/api/v2/agent-variants` were denied. Without a third deny, a container could reach the registration
  endpoint through it and rename or re-picture any other agent. The worker calls the backend directly,
  so the deny costs nothing. This is the same smuggling risk `composioExecAuth` was built to avoid, and
  it is worth checking for on any future agent-key endpoint.

An off-CDN avatar drops the picture and keeps the name rather than failing the registration — unlike
the human path, this caller is a machine mid-join with nobody to tell, and a nameless agent is worse
than a pictureless one.

### Avatar storage

Reuse the existing `GET /v2/attachments/presigned` (public-read, uuid key, `CDN_BASE_URL`) — it is
already how the ciphertext gets uploaded today; we simply stop encrypting the bytes first. Two
requirements:

1. **Host validation on write.** `avatarUrl` must be under `CDN_BASE_URL`, or `400`. Without this a
   malicious client could point a profile at an arbitrary URL (an IP-logging endpoint, someone else's
   photo). Clients enforce the same rule on the inbound XMTP signal.
2. **Lifecycle exemption.** The assets bucket has an S3 expiration lifecycle (see
   `src/api/v2/assets/handlers/lifecycle-status.ts`, `renew-batch.ts`). Profile avatars must go under a
   prefix (`profiles/`) that the expiry rule excludes, or they will silently vanish. **This is the single
   most likely way to ship a bug that only shows up days later.**

Optionally: server-side resize/re-encode to a bounded square on upload. Convos has already been bitten
by a 43.5 MB avatar in production; a hard cap here is cheap insurance.

## Wire format (convos-ios + convos-cli)

`ProfileUpdate` **v2** — bump the content type to `convos.org/profile_update:2.0`:

```proto
message ProfileUpdate {          // v2
  optional string name        = 1;
  reserved 2;                    // was encrypted_image
  MemberKind member_kind      = 3;
  map<string, MetadataValue> metadata = 4;   // unchanged — see below
  optional string avatar_url  = 5;
  optional uint64 version     = 6;           // backend Profile.version
}
```

- **Why a major bump rather than adding fields to 1.0:** v1 semantics say "absent image ⇒ cleared".
  A 1.0-shaped message with no `encrypted_image` would make old clients blank out the sender's avatar.
  Old clients ignore an unknown content type entirely, so a `2.0` bump makes them keep showing the last
  avatar they had — stale, not broken.
- **`metadata` and `member_kind` stay exactly as they are.** They are genuinely conversation-scoped
  (`connections` grants written by `CloudConnectionGrantWriter`, `timezone`, agent `variant`
  attestation). This plan does not touch them; they keep riding the same message.
- **`ProfileSnapshot` is deleted.** Its whole job — give a new joiner everyone's profile despite MLS
  forward secrecy — is now `POST /v2/profiles/batch` over the member list. New clients stop sending it
  and stop reading it; `PostPairProfileSnapshotBroadcaster` goes with it.

## iOS design

### Storage

One table, no conversation dimension:

```
profile(inboxId PK, name, avatarUrl, version, updatedAt, fetchedAt)
```

**There is no `source` column, because there is no second source.** Precedence disappears entirely
rather than collapsing to two tiers: `ProfileSource`, `ProfileMerge`, `DBProfileAvatar`,
`DBProfileAvatarSource`, and `ProfileBackfill` all go away. Nothing in the app authors another
person's name:

- `ProfileSource.contact` is not a local override — it is the *lowest* tier, written only by
  `ProfileBackfill` at an epoch-floor timestamp to seed the canonical store from legacy
  `DBMemberProfile` rows. It fills blanks and is superseded by any real event. It is a migration
  artifact whose lifetime ends with the migration.
- **Contact-authoritative naming was already deliberately removed.** `Contact.memberAwareResolver`
  and `Profile.overlaying(contact:)` are deprecated no-ops kept only so call sites compile — their
  own docs say "identity is now sourced authoritatively from the `Profile` database; contact data
  never overrides it." `Profile+ContactOverlay.liveOverride` is explicitly labelled an interim
  stopgap to delete at this refactor.
- There is **no local nickname feature**. `DBContact.displayName`/`avatarURL` are a mirror of the
  member profile written by `ContactsWriter.updateProfileIfNewer` (most-recent-wins), not anything
  the user typed.

So `DBContact` keeps its real job — the contacts list, `addedAt`/`addedViaConversationId`, blocking —
and loses its identity columns, reading name and avatar from `profile` by `inboxId` like every other
surface. That removes the mirroring path (`mirrorMemberProfileToContactInTransaction`), the
avatar-freshening stopgap, and the class of bug where the contacts list shows a different face than
the message bubble.

If a local nickname is ever wanted as a *product* feature, it can be added then as its own
user-authored column. It should not be inherited now from a tier that never did that job.

### Resolver

An actor that, given inbox ids, returns rows and refreshes what is missing or older than a TTL
(suggest 24 h, with immediate invalidation on the XMTP signal). Coalesces concurrent requests,
batches ≤ 100 per call, backs off on failure, and never blocks rendering — the view shows the cached
row or a monogram and updates reactively when the fetch lands.

### Rendering

`UnifiedProfile` survives, minus the per-conversation avatar map:

```swift
public struct UnifiedProfile {
    public let inboxId: String
    public let name: String?
    public let avatarUrl: URL?          // was avatars: [String: Avatar] + displayAvatar(for:)
    let memberKind: DBMemberKind?
    public let metadata: ProfileMetadata?
    let updatedAt: Date
}
```

**Nothing in the app target reads `UnifiedProfile` today** (0 references outside ConvosCore) — the
cutover was built but never flipped. That is a gift: we redirect the in-flight unified-profile work
instead of finishing it and then undoing it, and the view-layer churn is a one-time swap of
`ConversationMember.profile: Profile` (conversation-scoped) for the per-inbox type.

Avatars become plain URLs through the ordinary image cache: no salt, no nonce, no per-group key, no
`EncryptedImagePrefetcher`, and — for the first time — real CDN and HTTP caching.

### Write + fan-out

```
1. upload photo (presigned)          — only if the photo changed
2. PUT /v2/profiles/me               — source of truth; on failure, nothing is announced
3. enqueue fan-out                   — ProfileUpdate v2 to recently active conversations
```

Because step 3 no longer encrypts, uploads, or commits metadata, it does not need the current
job-queue machinery. A bounded, retrying background task is enough.

Propagation is three layers, cheapest first — **decided: the signal carries values, and eager fan-out
is scoped to recently active conversations** (decisions 1 and 2):

1. **Eager**, on change: `ProfileUpdate` v2 to conversations with activity in the last 30 days, plus
   the one currently open. This is the case that has to feel instant.
2. **Lazy**, as a backstop: the existing "publish before send / on open" hook already covers any
   conversation the user returns to, with one `version` stamp per conversation so a resend is a no-op.
   Nearly free now that a publish is one small message.
3. **Pull**, for everything else: the recipient's resolver fetches on cache miss or TTL expiry. A
   conversation dormant on *both* sides costs nothing until someone looks at it.

The 30-day window is a starting value, not a constant to defend — the pull path makes it safe to
tune down. Sizing it by count instead (e.g. top 200 by recency) is equivalent; pick whichever the
conversation-list query already supports cheaply.

### NSE

Reads the local `profile` table as it does now. On a miss, one best-effort batch fetch inside a short
budget (it already holds an NSE-scoped token), falling back to the existing generic title. Simpler
than today, where the NSE participates in the four-source merge.

One server-side prerequisite when that lands: NSE tokens are confined to a hardcoded path allowlist
(`NSE_ALLOWED_PATHS`, currently just `/api/v2/auth-check`), and the profiles routes are mounted with
plain `authMiddleware`, which rejects them. Widening the allowlist to `/api/v2/profiles/batch` and
mounting with `authMiddlewareAllowNSE` is deliberately left until the client consumer exists — an
allowlist entry added ahead of its consumer is one nobody later remembers to remove.

## Migration and rollout

| Concern | Handling |
|---|---|
| **My own profile** | On first launch of the new build, upload `DBMyProfile` (name + decrypted avatar bytes) via the normal write path. Idempotent, one-shot flag. |
| **Other people's profiles** | Backend has never seen them, so no server backfill is possible. Seed the new `profile` table with **names** from existing `DBProfile`/`DBMemberProfile` rows. Avatars fill in as each person upgrades and publishes; until then, keep rendering the legacy encrypted avatar from the old row as a read-only fallback for one release, then drop it. |
| **Old clients** | Ignore `profile_update:2.0` (unknown type) → they keep the last profile they saw. New clients keep *reading* the v1 rails until the counter says otherwise, so upgraded users still see un-upgraded ones change. Neither direction breaks. |
| **appData** | Stop writing `ConversationProfile` entirely at cutover — that removes the encryption, the upload, and the MLS commit per conversation. Accepted consequence: post-cutover signups render as "Somebody" on un-upgraded clients. Keep the proto field reserved forever. See *Retiring the v1 read path*. |
| **Force-upgrade** | No such lever exists in either repo, and this plan does not build one. Retire the v1 read path on a measured counter instead. See *Retiring the v1 read path*. |

## Privacy and security — the honest tradeoffs

Say these out loud before building, because they are real changes in posture:

1. **The backend learns every user's display name and photo.** Today it does not. This is inherent to
   the request and is how essentially every messenger works, but it is a new class of data on our
   servers, and it should be covered by retention/deletion (cascade from `Account`, and delete the S3
   object on avatar clear + account deletion).
2. **Avatar URLs are publicly fetchable by anyone who has the link.** Unguessable UUID key, no auth on
   the CDN. That is the point of the simplification; it should be a deliberate, recorded decision.
3. **Any authenticated Convos user can resolve an inbox id → name + photo.** The backend cannot verify
   MLS group membership (it is not an XMTP node and never sees group state), so "only people in a
   conversation with you" is not enforceable server-side. Mitigations: authenticated-only reads, batch
   size cap, per-account rate limits, and no enumeration surface (lookup by exact inbox id only, never
   by prefix or by name search).
4. **Spoofing is closed on both channels.** The XMTP signal is sender-authenticated by construction
   (the inbox id is implicit in the message). The backend write path is bound to the SIWE-verified
   address. The one new hole — a hostile `avatar_url` in the signal — is closed by host-validating
   against the CDN on both sides.
5. **Profile rendering gains a backend dependency.** Offline or during an outage, clients render from
   the local table (and the signal itself carries name + URL, so most updates need no fetch at all).
   No profile change is ever *lost*: it is in the backend, and the next revalidation picks it up.

## Delivery plan

Each phase is independently shippable and leaves the app working.

| # | Phase | Repo(s) | Notes |
|---|---|---|---|
| 1 | ✅ **Done** — `Profile` model + migration, inbox binding, 5 endpoints, `profiles/` avatar prefix, 21 tests | backend | Branch `jarod/backend-profiles`. Full suite green (1972 passed). The bucket lifecycle exclusion is an AWS-side action, not code |
| 2 | ✅ **Done** — Read path: `profile` table, resolver, backend fetch, `UnifiedProfile` shape change | ios | PRs #1345 (API client) + #1346 (resolver). Behind a flag; nothing renders from it yet |
| 3 | ✅ **Done** — View cutover: `ConversationMember` and every avatar/name site read the per-inbox profile; plain-URL avatars | ios | PR #1348. The visible change; largest single PR. Ships the "resolved only via v1" counter — the retirement trigger needs a baseline from day one |
| 4 | ✅ **Done** — Write path: upload → `PUT` → fan-out; `ProfileUpdate` v2 encode/decode. The appData write stops here | ios, convos-cli | PR #1387 (iOS) + convos-cli #137. v1 read kept; nothing is mirrored any more. The CLI reads v2 but keeps *sending* v1 — see below |
| 5 | ✅ **Done (agent parity)** — `AgentProfile` + `POST /v2/profiles/agent`, worker registers at join, container proxy denied | backend, assistants | Agent avatars were already plain URLs, so nothing to unwind. `herald-lite` + `convos-cli` move to phase 4 with the rest of the wire format |
| 6a | ✅ **Done** — Stop relaying `ProfileSnapshot`: all four send sites, `ProfileSnapshotBuilder`, `PostPairProfileSnapshotBroadcaster`. Inbound snapshots still read | ios | PR #1388 |
| 6b | Delete `DBProfileAvatar*`, shrink `ProfileMerge`/`ProfileSource` to the two tiers that survive the snapshot retirement | ios | The bulk of the removal |
| 6c | Delete `ProfileBackfill` + the contact identity mirror | ios | **Rollout-gated, not free** — see below |
| 7 | Delete the v1 avatar read and the encrypted-image profile stack | ios | Gated on ~90% of active sessions on the cutover build |
| 8 | Delete the v1 name read + appData profile parsing; retire legacy `DBMemberProfile` (344 references) | ios | Gated on the counter, not a date. Mechanical PR |

Group **images** keep their per-group encryption (`imageEncryptionKey`, `encryptedGroupImage`) — that
is a separate decision with a separate blast radius, and `EncryptedImageLoader`/`EncryptedImageService`
stay for it. Worth a follow-up conversation, not this plan.

## Decisions

1. **The signal carries values.** `{name, avatar_url, version}` rides the `ProfileUpdate` v2 message,
   so the common case is zero-fetch. The backend stays authoritative on revalidation, and clients
   host-validate `avatar_url` against the CDN before honoring it.
2. **Eager fan-out is scoped to recently active conversations** (30 days as the starting window), with
   the lazy on-open/on-send hook and the pull path covering everything else. See *Write + fan-out*.
3. **No name validation beyond a length cap.** The same freedom as today; no uniqueness, no
   reservation, no moderation gate.
4. **No minimum-version gate. Retire the v1 read path by measurement, not by date.** Expanded below,
   because the original framing assumed a lever that does not exist.
5. **No compatibility mirror.** The `appData` write stops at cutover rather than lingering a release in
   name-only form. Post-cutover signups render as "Somebody" on un-upgraded clients until those clients
   update; that is accepted, not a defect.

## Retiring the v1 read path

### The question is not "which version" — there is no gate to set

Neither repo has an app-version mechanism. `RuntimeConfig` has exactly one key in use
(`app_attest_enabled`), no middleware inspects a client version, no request carries one, and
`DeviceRegistration` does not store one. "Set a minimum supported version" would mean *building* a
force-upgrade lever: a client-side gate, a backend config, and the operational risk of bricking every
install if it is ever misconfigured.

**Recommendation: don't build one for this project.** The degradation below is graceful — a stale name
and a monogram — not a broken app, and that does not justify a lever whose worst failure mode is worse
than the problem it solves. Whether Convos wants a force-upgrade capability in general is a real
question, but it should be decided on its own merits, not smuggled in as a dependency of this work.

### What actually breaks, for whom

Four pairings, given that the signal carries values:

| | Sees a **new** client's profile | Sees an **old** client's profile |
|---|---|---|
| **New client** | Full path — signal, then backend | **The deciding case.** An old user never writes to the backend, so `/v2/profiles/batch` has nothing. Only the v1 rails can answer. |
| **Old client** | Cannot decode `profile_update:2.0`; keeps the last value it saw. A *brand-new* user it has never seen renders nameless. | Unchanged |

Two refinements matter more than the matrix itself:

- **The three v1 sources have different half-lives.** appData is *state* — present in the group at
  sync time, so it self-heals on a fresh install or a newly paired device. `ProfileSnapshot` is a
  replayable event, and v1 `ProfileUpdate` only ever helps a client that was present when it was sent.
  So they retire in that order, not as one switch.
- **Names and avatars should retire separately.** Keeping v1 *names* is cheap parsing. Keeping v1
  *avatars* means keeping the entire encrypted-image read stack (salt, nonce, per-group key, the
  bespoke decrypt-and-cache path) — the single biggest thing this plan deletes. Dropping v1 avatars
  early costs an un-upgraded user their photo but keeps their name: a monogram instead of a face,
  rather than "Unknown".

### Decided: no compat mirror. The appData write stops at cutover

This was the one place worth considering a dual-write, and the call is to skip it.

The consequence, stated plainly so nobody re-litigates it later or files it as a regression: an old
client has no history for someone it has never seen, so `Profile.displayName` falls through to its
literal placeholder. **A user who signs up after the cutover renders as "Somebody" on un-upgraded
clients** — in every conversation they share with a member who hasn't updated — until that member
updates. Names of people the old client already knows are unaffected; they just stop changing.

The alternative was mirroring name-only into `appData` for one release (cheap half: no encryption, no
upload, and `merged(over:)` preserves an existing image so it could not blank an avatar). It was
rejected: it keeps an MLS commit per conversation alive for the benefit of a population that is on its
way out, and it is the last thing holding the appData write path open. Deleting the write at cutover
is what makes phases 6–8 a straight demolition rather than a staged one.

If support starts seeing "Somebody" reports at volume, the mirror is a small, well-understood patch to
add back — the code exists today and would only need its avatar half removed.

### Correction: `ProfileBackfill` is rollout-gated, not a phase-6 freebie

The original phase-6 line listed `ProfileBackfill` alongside the snapshot relay, as
if both were dead weight. They are not the same kind of thing.

`Profile.from` reads the name from `DBProfile` and nothing else — there is no
fallback to legacy `DBMemberProfile`. For a peer who predates the profile tables
and has not since sent a profile event or written to the backend, the *only*
thing that ever puts a row in `DBProfile` is the backfill. Delete it and those
names go blank on upgrade.

It is a one-time migration, so it does become dead — once every active install
has launched the build that contains it. That is the same rollout gate phases 7
and 8 carry, and it belongs on this deletion too.

`ProfileMerge` and `ProfileSource` are a related but smaller correction: with the
snapshot tier gone and the appData write stopped, the precedence engine is down
to two live tiers instead of four. It shrinks; it does not vanish, because the
v1 sources that remain still need ordering against each other.

### Decided: the CLI reads v2 but keeps sending v1

`@xmtp/node-sdk` keys its codec registry on the full content-type string, version
included, so a v2 message finds no codec and arrives as raw `EncodedContent`.
Reading v2 therefore needs a registered `ProfileUpdateV2Codec`, not just a
version-tolerant matcher — that part is not optional.

Sending is the opposite call. The proto is a superset: `avatar_url` and `version`
ride along fine on a v1-typed message, and every client decodes them, iOS
included — its `ProfileUpdateV1Codec` decodes into the same generated type. So
bumping the CLI's send version would buy nothing and cost real breakage: an
agent's name updates would go invisible to every client older than the v2
release. iOS bumps because it genuinely stopped sending encrypted images and
needs to say so; the CLI never sent them, because agent avatars were already
plain URLs.

The asymmetry is the point. A version bump should announce a break in what the
sender speaks, not track a schema revision.

Remaining: `herald-lite` surfacing `avatarUrl`/`version` on its `profile_update`
webhook. Blocked on the CLI publishing to npm and the catalog moving off 0.10.15
— nothing in the app depends on it.

### The trigger: instrument it, don't schedule it

Add a counter on the new client for profiles resolved **only** via a v1 source, tagged by which one.
That measures the thing we actually care about — "are we still learning anything from v1?" — rather
than a proxy for it. Cross-check against Sentry's `release` distribution for the share of active
sessions still on pre-cutover builds; Sentry is initialized at launch (`SentryConfiguration.configure()`),
so that data exists today without new work.

Then:

| Delete | When |
|---|---|
| `ProfileSnapshot` read | Same release as the write. It is redundant with the batch endpoint between new clients, and duplicates appData for old ones. |
| v1 **avatar** read (and with it the encrypted-image profile stack) | Once the cutover build passes ~90% of active sessions. Un-upgraded users keep their names, lose their photos. |
| v1 **name** read + appData profile parsing | Once the "resolved only via v1" counter is effectively flat at zero — expect 2–3 release trains, but let the number say so. |

If the counter refuses to fall — a large cohort stuck on an old build — that is the signal to
reconsider a force-upgrade lever, with evidence, instead of guessing at one now.
