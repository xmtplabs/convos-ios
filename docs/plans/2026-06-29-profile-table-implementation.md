# Technical design: Profile-table identity refactor (iOS)

- Status: draft for review (architect design)
- Date: 2026-06-29
- Spec: `docs/specs/profile-contact-identity-model.md` (2026-06-29 update is the
  decided direction)
- Deferred follow-up: `docs/adr/014-cross-conversation-profile-image-caching.md`
  (digest cache - out of scope here; reserve columns only)

This is the detailed technical design for "populate all views from `Profile`,
instead of `MemberProfile`." It turns the spec into concrete iOS types, file
paths, signatures, and a stacked-PR sequence. It mirrors the shipped Android
design while respecting iOS constraints.

## 1. Goals and non-goals

In scope:

- A canonical `DBProfile` store keyed by `inboxId`, owned by a new
  `ProfilesRepository`, as the single source of identity (name + avatar) for all
  views.
- Per-conversation avatar slots in `DBProfileAvatar` (encryption is per group).
- Self identity in `DBSelfProfile` plus a durable publish queue
  (`DBProfilePublishJob` + `DBProfileAvatarSource`) replacing the direct
  fan-out in `MyProfileWriter` / `ProfileSyncCoordinator`.
- A precedence + recency merge engine for inbound profile events.
- ViewModel-layer identity resolution replacing
  `@Environment(\.memberContactOverride)` and `Profile.overlaying(contact:)`.
- One-time `ProfileBackfill` and a `ConversationProfileCleaner`.
- Migrations, including a gated column-drop after backfill ships.

Non-goals (explicitly deferred):

- Cross-conversation avatar download dedup via advertised content digest
  (ADR 014). We only reserve two nullable columns so the follow-up needs no
  second migration.
- `localNickname` user-assigned override.
- `DBAgentTemplate` <-> agent profile sync (separate effort).

## 2. Constraints (from CLAUDE.md, must hold throughout)

- ConvosCore must compile on macOS: no `UIKit`, no `#if canImport(UIKit)`, use
  `ImageType`. Anything iOS-specific goes through a protocol implemented in
  ConvosCoreiOS or injected from the app.
- No force-unwraps / implicitly-unwrapped optionals; `guard let` early returns.
- SwiftLint: `enum Constant` at bottom of scope, sorted imports, max function
  body 125 lines, max type body 625 lines, max 6 params, no all-caps in
  comments, ASCII punctuation only.
- Type-check budget 100ms: hoist conditionals to typed `let`s in any new SwiftUI
  bodies; keep view bodies small.
- Use the `XMTPClientProvider` / `MessageSender` abstraction, never `XMTPiOS`
  types directly in business logic.
- Run `swift test --package-path ConvosCore` against the local XMTP Docker node
  before every push.

## 3. Architecture overview

```
View / ViewModel (Convos app target)
  reads identity via injected ProfilesRepositoryProtocol
        |
        v
ProfilesRepository (ConvosCore)  <-- warmed in-memory cache + merge engine
  |          |            |
  v          v            v
IProfileStore  ISelfProfileStore  IProfilePublishStore   (protocols)
  |          |            |
  GRDB impls (ConvosCore)   +   in-memory impls (tests)
        |
        v
GRDB DatabaseWriter/Reader  (SharedDatabaseMigrator schema)

Inbound:  StreamProcessor.processProfile*  ->  ProfilesRepository.apply(event)
Outbound: edit self  ->  ProfilesRepository.publishMyProfile  ->  ProfilePublisher
                          (durable queue)  ->  encrypt+upload+send via MessageSender
Lifecycle: SessionManager.init -> backfill -> warmUp; ConversationProfileCleaner
```

Everything new lives in ConvosCore except the ViewModel rewiring (app target) and
any image-key/upload bridges that already exist on the app/API side.

New directory: `ConvosCore/Sources/ConvosCore/Profiles/Repository/` for the
repository, stores, merge engine, publisher, backfill, and cleaner. DB models go
under the existing `Storage/Database Models/`. Migrations stay in
`SharedDatabaseMigrator.swift`.

## 4. Data layer

### 4.1 DB models (GRDB) - `Storage/Database Models/`

`DBProfile` (per-person identity, PK `inboxId`):

```swift
struct DBProfile: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    let inboxId: String
    var name: String?
    var memberKind: DBMemberKind?          // reuse existing enum
    var metadata: ProfileMetadata?         // existing JSON codable type
    var profileSource: ProfileSource       // see merge engine; persisted as text
    var avatarContentDigest: String?       // reserved for ADR 014, always nil now
    var updatedAt: Date
    enum Columns { /* inboxId, name, memberKind, metadata, profileSource, avatarContentDigest, updatedAt */ }
}
```

`DBProfileAvatar` (per-person, per-conversation slot, PK `(inboxId, conversationId)`):

```swift
struct DBProfileAvatar: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    let inboxId: String
    let conversationId: String
    var url: String?
    var salt: Data?
    var nonce: Data?
    var key: Data?
    var profileSource: ProfileSource
    var contentDigest: String?             // reserved for ADR 014, always nil now
    var updatedAt: Date
}
```

`DBSelfProfile` (current user canonical identity, PK `inboxId`):

```swift
struct DBSelfProfile: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    let inboxId: String
    var name: String?
    var metadata: ProfileMetadata?
    var updatedAt: Date
}
```

`DBProfileAvatarSource` (current user plaintext source image, PK `inboxId`):

```swift
struct DBProfileAvatarSource: Codable, FetchableRecord, PersistableRecord, Sendable {
    let inboxId: String
    var plaintext: Data
    var version: Int64        // bumped each time the user sets a new avatar
    var updatedAt: Date
}
```

`DBProfilePublishJob` (durable publish queue, PK `id`):

```swift
struct DBProfilePublishJob: Codable, FetchableRecord, PersistableRecord, Sendable {
    let id: String
    var seq: Int64                   // monotonic enqueue order
    var conversationId: String
    var sourceVersion: Int64?        // pins DBProfileAvatarSource.version; nil = name-only
    var hasAvatar: Bool
    var state: ProfilePublishJobState // pending | uploading | done
    var ciphertext: Data?            // cached after first encrypt
    var salt: Data?
    var nonce: Data?
    var groupKey: Data?
    var filename: String?
    var uploadedURL: String?
    var attemptCount: Int64
    var nextAttemptAt: Date
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
}

enum ProfilePublishJobState: String, Codable, Sendable { case pending, uploading, done }
```

`ProfileSource` (merge precedence, persisted as text):

```swift
enum ProfileSource: String, Codable, Sendable, Comparable {
    case contact          // 0 lowest (backfill)
    case appData          // 1
    case profileSnapshot  // 2
    case profileUpdate    // 3 highest
    // Comparable by the ordinal above
}
```

### 4.2 Migrations - `SharedDatabaseMigrator.swift`

Registered after the current latest migration, following the existing
`registerMigration(_:)` pattern. Keep each closure cheap.

1. `"createProfileTables"`: create `profile`, `profileAvatar`, `selfProfile`,
   `profileAvatarSource`, `profilePublishJob`. `profileAvatar.conversationId`
   gets a foreign key to `conversation(id)` with `ON DELETE CASCADE` (defense in
   depth alongside the cleaner). Indexes: `profilePublishJob(state, nextAttemptAt, seq)`
   and `profilePublishJob(conversationId)`.
2. No SQL backfill migration. `ProfileBackfill` runs as startup code (section 7)
   so it is testable and cheap, matching Android.
3. `"dropMemberProfileIdentityColumns"` (separate, shipped a release later):
   drop identity/avatar columns from `contact` and `memberProfile`. Gated so a
   partial upgrade never runs before the backfill has executed (guard on a
   stored "backfill completed" marker; skip the drop if absent).

Reserve `avatarContentDigest` / `contentDigest` columns in step 1 per spec
"Anticipating ADR 014"; they are created nullable and never written by this work.

## 5. Store layer - `Profiles/Repository/Stores/`

Three protocols, each with a GRDB implementation (ConvosCore) and an in-memory
implementation (tests). Stores are thin: persistence + change signals only; all
merge logic lives in the repository.

`IProfileStore`:

```swift
protocol IProfileStore: Sendable {
    // identity
    func saveIdentity(_ profile: DBProfile) async throws
    func identity(inboxId: String) async throws -> DBProfile?
    func identities(inboxIds: [String]) async throws -> [DBProfile]
    func allIdentities() async throws -> [DBProfile]
    // avatars
    func saveAvatar(_ avatar: DBProfileAvatar) async throws
    func avatar(inboxId: String, conversationId: String) async throws -> DBProfileAvatar?
    func avatars(inboxId: String) async throws -> [DBProfileAvatar]
    func avatars(inboxIds: [String]) async throws -> [DBProfileAvatar]
    func allAvatars() async throws -> [DBProfileAvatar]
    func deleteAvatars(conversationId: String) async throws
    // lifecycle
    func delete(inboxId: String) async throws
    func deleteAll() async throws
    // signal
    var events: AsyncStream<ProfileStoreEvent> { get }
}

enum ProfileStoreEvent: Sendable {
    case identityChanged(inboxId: String)
    case avatarChanged(inboxId: String, conversationId: String)
    case removed(inboxId: String)
}
```

`ISelfProfileStore`:

```swift
protocol ISelfProfileStore: Sendable {
    func save(_ profile: DBSelfProfile) async throws
    func load() async throws -> DBSelfProfile?
    func clear() async throws
    var updates: AsyncStream<Void> { get }
}
```

`IProfilePublishStore`:

```swift
protocol IProfilePublishStore: Sendable {
    // source image
    func setSource(_ source: DBProfileAvatarSource) async throws
    func source(inboxId: String) async throws -> DBProfileAvatarSource?
    func clearSource(inboxId: String) async throws
    // job queue
    func enqueue(_ job: DBProfilePublishJob) async throws
    func update(_ job: DBProfilePublishJob) async throws
    func job(id: String) async throws -> DBProfilePublishJob?
    func claimNextReady(now: Date) async throws -> DBProfilePublishJob?
    func activeJobs() async throws -> [DBProfilePublishJob]
    func jobs(conversationId: String) async throws -> [DBProfilePublishJob]
    func nextSeq() async throws -> Int64
    func earliestNextAttempt() async throws -> Date?
    func deleteJob(id: String) async throws
    func deleteJobs(conversationId: String) async throws
    func supersedeOlderThan(conversationId: String, seq: Int64) async throws
    func deleteAll() async throws
    var events: AsyncStream<ProfilePublishEvent> { get }
}

enum ProfilePublishEvent: Sendable {
    case enqueued(id: String, conversationId: String)
    case updated(id: String)
}
```

GRDB impls: `GRDBProfileStore`, `GRDBSelfProfileStore`, `GRDBProfilePublishStore`,
each taking `databaseWriter`/`databaseReader`, emitting events via a continuation
on write. In-memory impls: dictionaries guarded by an `actor`. `claimNextReady`
filters `state != done && nextAttemptAt <= now`, returns the minimum by `seq`.

## 6. ProfilesRepository - `Profiles/Repository/ProfilesRepository.swift`

Protocol (app and other ConvosCore code depend only on this):

```swift
public protocol ProfilesRepositoryProtocol: Sendable {
    // lifecycle
    func warmUp() async
    func stop() async
    // read - others
    func profilesPublisher(inboxIds: [String]) -> AnyPublisher<[String: Profile], Never>
    func profiles(inboxIds: [String]) async -> [String: Profile]
    func profilePublisher(inboxId: String) -> AnyPublisher<Profile?, Never>
    func profile(inboxId: String) async -> Profile?
    func sortedFilteredProfileInboxIds(_ inboxIds: [String], query: String) async -> [String]
    // read - self
    func selfProfilePublisher() -> AnyPublisher<Profile, Never>
    func selfProfile() async -> Profile?
    func selfAvatarSourceBytes() async -> Data?
    // write - self
    func updateSelfProfile(_ edit: SelfProfileEdit) async throws
    func publishMyProfile(displayName: String?, avatarBytes: Data?, priorityConversationId: String?) async throws
    func publishMyProfileToConversation(_ conversationId: String) async throws
    // inbound seam
    func apply(_ event: ProfileDomainEvent) async
    var profileChanges: AnyPublisher<String, Never> { get }   // inboxId on any change
    // cleanup
    func purgeConversationAvatars(_ conversationId: String) async
    // session binding (publisher needs XMTP image keys + send)
    func bind(session: ProfilePublishSession?) async
}
```

Key internals:

- Warmed in-memory cache: `[String: Profile]` plus `[String: [conversationId: Avatar]]`,
  populated in `warmUp()` from `allIdentities()` + `allAvatars()` + `selfProfile`.
  Reads serve from cache; writes update cache then persist. Cache mutations are
  serialized on an internal `actor`.
- `profilePublisher` / `profilesPublisher` back onto a Combine subject fed by
  store events and cache mutations; `profileChanges` emits the changed `inboxId`
  for downstream repos/read-models to invalidate.
- The Combine surface keeps the app's existing `@Observable` ViewModels simple;
  if a ViewModel prefers async, the snapshot `profiles(inboxIds:)` is available.

`Profile` model change: today `Profile` is conversation-scoped
(`id = inboxId@conversationId`, carries one avatar). New shape is per-person with
per-conversation avatars and an explicit display resolver:

```swift
public struct Profile: Identifiable, Hashable, Sendable {
    public var id: String { inboxId }
    public let inboxId: String
    public let name: String?
    public let memberKind: DBMemberKind?
    public let metadata: ProfileMetadata?
    public let avatars: [String: Avatar]   // keyed by conversationId
    public let updatedAt: Date
    public func displayAvatar(for conversationId: String?) -> Avatar?  // slot, else newest
    public static func empty(inboxId: String) -> Profile
}
```

`Avatar` value type (spec Revision 6):

```swift
public enum Avatar: Hashable, Sendable {
    case plain(url: String, updatedAt: Date)
    case encrypted(url: String, salt: Data, nonce: Data, key: Data, updatedAt: Date)
    public static func from(url: String?, salt: Data?, nonce: Data?, key: Data?, updatedAt: Date) -> Avatar?
}
```

`ImageCacheable` conformance moves onto `Avatar` (with the conversation-scoped
identity key preserved), so `AvatarView` takes an `Avatar` or a `(Profile,
conversationId)` pair rather than the old per-conversation `Profile`.

### 6.1 Merge engine - `Profiles/Repository/ProfileMerge.swift`

Pure functions, no I/O, fully unit-testable:

```swift
enum ProfileMerge {
    static func mergeIdentity(existing: DBProfile?, incoming: IncomingIdentity, source: ProfileSource, sentAt: Date) -> DBProfile
    static func mergeAvatar(existing: DBProfileAvatar?, incoming: IncomingAvatar, source: ProfileSource, sentAt: Date) -> DBProfileAvatar?
    // helpers
    static func fillBlank(_ existing: String?, _ incoming: String?) -> String?
    static func preserveVerifiedKind(_ existing: DBMemberKind?, _ incoming: DBMemberKind?) -> DBMemberKind?
}
```

Rules (spec Revision 3 + existing guards):

- Higher `ProfileSource` always wins; equal source -> newer `sentAt` wins; lower
  source only fills blanks (`fillBlank`).
- Name: empty/absent never clears a populated name.
- Avatar tri-state: only `set` or `explicit-clear` changes the slot; `silent`
  leaves it.
- `preserveVerifiedKind`: never downgrade `agent:convos` / `agent:user-oauth` to
  generic `agent`.

`apply(_ event:)` decodes the event to `IncomingIdentity` / `IncomingAvatar`,
runs the merge, persists via the stores, updates the cache, and emits
`profileChanges`. Self-echo guard: events whose sender is the current inbox are
ignored (self identity is authored locally).

### 6.2 ProfileDomainEvent - `Profiles/Repository/ProfileDomainEvent.swift`

```swift
public enum ProfileDomainEvent: Sendable {
    case profileUpdated(inboxId: String, conversationId: String, identity: IncomingIdentity, avatar: IncomingAvatar?, sentAt: Date)
    case profileSnapshotReceived(inboxId: String, conversationId: String, identity: IncomingIdentity, avatar: IncomingAvatar?, sentAt: Date)
    case appDataProfilesObserved(/* ... */)
}
```

`IncomingAvatar` distinguishes `.set(url,salt,nonce,key)`, `.explicitClear`, and
`.silent` so the tri-state survives into the merge.

## 7. Self profile + durable publisher

### 7.1 SelfProfileEdit DSL

```swift
public struct SelfProfileEdit: Sendable {
    public enum Field<T: Sendable>: Sendable { case keep; case set(T) }
    public var name: Field<String?> = .keep
    public var metadata: Field<ProfileMetadata?> = .keep
}
```

`updateSelfProfile` reads current `DBSelfProfile`, applies set fields, persists,
and enqueues name-only publish jobs for all conversations.

### 7.2 ProfilePublisher - `Profiles/Repository/ProfilePublisher.swift`

An `actor` owned by `ProfilesRepository`, backed by `IProfilePublishStore`.
Replaces the direct `MyProfileWriter.update*` / `syncFromGlobalProfile` /
`ProfileSyncCoordinator` fan-out.

```swift
actor ProfilePublisher {
    func bind(_ session: ProfilePublishSession)
    func unbind()
    func publish(avatarBytes: Data?, priorityConversationId: String?) async throws
    func publishConversation(_ conversationId: String) async throws
}
```

`ProfilePublishSession` is the injected seam to XMTP + upload, keeping the
publisher free of `XMTPiOS`:

```swift
public protocol ProfilePublishSession: Sendable {
    var inboxId: String { get }
    func allConversationIds() async throws -> [String]
    func ensureImageKey(conversationId: String) async throws -> Data?   // nil -> drop job
    func uploadEncryptedAvatar(_ ciphertext: Data, filename: String) async throws -> String
    func sendProfileUpdate(_ update: ProfileUpdate, conversationId: String) async throws
}
```

The app/MessagingService provides the concrete implementation, reusing today's
`apiClient.uploadAttachment(...)`, `ImageEncryption.encrypt(...)`,
`ProfileUpdateCodec`, and `messageSender(for:)` -> `send(encodedContent:)`.

Drain loop:

1. `publish` records the source image (`setSource`, bump `version`), then
   enqueues one `DBProfilePublishJob` per conversation, priority conversation
   first; `supersedeOlderThan` drops superseded intents.
2. Single loop claims `claimNextReady`, encrypts once (caches ciphertext + crypto
   on the job so restarts re-upload identical bytes), uploads, sends, writes the
   local `DBProfileAvatar` slot, marks job `done`, emits a member-profile-updated
   signal.
3. Failure reschedules only that job (capped exponential backoff + jitter); the
   loop moves on (no head-of-line blocking). `sourceVersion` pins the source;
   stale-version jobs drop without uploading.
4. Republish a conversation when its group image key rotates (observe the
   conversation store), only for conversations already carrying an encrypted
   avatar.

This subsumes `ProfileSyncCoordinator` (delete it once callers move over).

## 8. Backfill + cleaner

`ProfileBackfill` - `Profiles/Repository/ProfileBackfill.swift`:

```swift
struct ProfileBackfill {
    func run() async throws   // idempotent, safe to re-run
}
```

Reads all `DBMemberProfile` rows; for non-self inboxes writes identity into
`DBProfile` and avatars into `DBProfileAvatar` via the merge at
`ProfileSource.contact` with a floor timestamp (epoch 0) so any real later event
supersedes; seeds `DBSelfProfile` from the current user's own rows if empty;
writes a persisted "backfill completed" marker (gates the later column-drop
migration). Runs once at startup before `warmUp()`.

`ConversationProfileCleaner` - `Profiles/Repository/ConversationProfileCleaner.swift`:
an object observing conversation deletions (hook the existing delete path in
`SessionStateMachine` / conversation deletion) and calling
`purgeConversationAvatars(conversationId)`. The FK cascade is defense in depth;
the cleaner matches Android and covers non-cascade stores. Identity in
`DBProfile` is preserved.

## 9. Inbound seam - `Syncing/StreamProcessor.swift`

`processProfileUpdate` and `processProfileSnapshot` keep decoding and the
existing agent-verification logic, but the write target changes:

- Replace the `ContactsWriter.saveMemberProfileAndMirrorToContactInTransaction`
  call with construction of a `ProfileDomainEvent` and a call to
  `profilesRepository.apply(event)`.
- During transition, `DBMemberProfile` retains only membership/role/`memberKind`
  needed by non-identity consumers; the identity/avatar fields it still has are
  no longer read for rendering (and are dropped in the gated migration).
- Inject `profilesRepository` into `StreamProcessor` via its initializer (it is
  already constructed inside `MessagingService`).

Snapshot precedence (skip-if-present today) becomes the merge's
`profileSnapshot` source level, removing the ad hoc skip.

## 10. ViewModel rewiring (app target)

Retire `@Environment(\.memberContactOverride)` (`Convos/Contacts/MemberNameOverride.swift`)
and `Profile.overlaying(contact:)` (`Convos/Contacts/Profile+ContactOverlay.swift`).
Replace with `ProfilesRepositoryProtocol` injected into each ViewModel, plus a
small set of pure display helpers:

`ConversationDisplay` (app target, pure functions over `[String: Profile]`):

```swift
enum ConversationDisplay {
    static func name(inboxId: String, _ profiles: [String: Profile]) -> String
    static func formattedNames(_ members: [ConversationMember], _ profiles: [String: Profile]) -> String
    static func sortedByRole(_ members: [ConversationMember], _ profiles: [String: Profile]) -> [ConversationMember]
    static func conversationDisplayName(_ conversation: Conversation, _ profiles: [String: Profile]) -> String
}
```

Surfaces to rewire (each obtains profiles via the repository for the inboxIds it
renders, with `Profile.empty` fallback preserving "Somebody"/"Agent"):

- `Convos/Conversations List/ConversationsViewModel.swift` and its
  `ConversationsViewController` / `ConversationListItemCell` (was
  `memberContactOverride`).
- `Convos/Conversation Detail/ConversationViewModel.swift` and the message list
  (`MessagesViewRepresentable` / `MessagesViewController` /
  `MessagesListItemTypeCell`).
- `Convos/Contacts/ContactsViewModel.swift` (contact list -> repository
  `sortedFilteredProfileInboxIds` + per-row profile lookup).
- Contact card / member detail VMs.
- Read-by / read-receipts VM.
- `AvatarView` / `ProfileAvatarView` / `ConversationAvatarView` /
  `MessageAvatarView`: take an `Avatar` (resolved via `Profile.displayAvatar(for:)`).
- `Convos/Profile/ProfileSettingsViewModel.swift` and `MyProfileViewModel.swift`:
  read/write self via `selfProfilePublisher` / `publishMyProfile`.

Watch the type-check budget in any touched SwiftUI body (hoist conditionals).

### 10.1 Interim avatar-freshness fix to remove during cutover

Before this refactor lands, system-message and read-receipt rows render a
participant's avatar from a stale source after a profile-image change: the rows
resolve through a per-message `Profile` snapshot (whose avatar URL goes stale)
overlaid with the lagging `DBContact`, while the message bubble already renders
the current per-conversation member profile. A stopgap was added to bring those
rows to parity with the bubble, and it becomes dead code once identity resolves
from `ProfilesRepository`; delete it in PR9:

- Member-backed contact override: `Contact.liveOverride(member:stored:)` in
  `Convos/Contacts/Profile+ContactOverlay.swift`, consumed by
  `ConversationView.contactOverride`. It prefers the current conversation
  member's avatar (the same source the bubble uses) over the lagging stored
  contact. `displayAvatar(for:)` already returns the conversation's avatar slot
  from the canonical store, so this helper and the whole `memberContactOverride`
  / `overlaying(contact:)` path go away together. This also covers the current
  user, since self is a conversation member.

This is a correctness stopgap, not new architecture: it feeds the existing render
path the freshest data available today rather than changing how identity is
stored, so it retires cleanly when the repository becomes the source of truth.

## 11. Composition root + lifecycle

`ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` and
`Messaging/MessagingService.swift`:

- Add factory methods on `MessagingService`: `profileStore()`,
  `selfProfileStore()`, `profilePublishStore()`, and `profilesRepository()`
  (constructed once, cached like other services), wiring `databaseWriter` /
  `databaseReader`.
- Provide a concrete `ProfilePublishSession` from `MessagingService` (it owns the
  XMTP client provider, apiClient, codecs) and `bind` it to the repository.
- In `SessionManager.init`'s initialization task, after
  `prewarmUnusedConversation()` and before first UI read: run
  `ProfileBackfill().run()` (once), then `profilesRepository().warmUp()`, then
  start `ConversationProfileCleaner`.
- On teardown: `ConversationProfileCleaner` stop, `profilesRepository().stop()`
  (unbinds publisher, cancels observers).
- Inject `profilesRepository` into `StreamProcessor` at its construction site.

## 12. Stacked PR plan (Graphite)

Each checkpoint compiles and has its package tests passing before stacking the
next. PR 1 is this design doc.

Progress: PR 1 done (this doc + spec + ADR 014/015). PR 2 done (models, migration,
value types, tests). PR 3 is next.

1. `profile-table-plan` - this document. [done]
2. `profile-table-models-migrations` - DB models (`DBProfile`, `DBProfileAvatar`,
   `DBSelfProfile`, `DBProfileAvatarSource`, `DBProfilePublishJob`) +
   `createProfileTables` migration + `ProfileSource` + `Avatar` + unit tests for
   models and migration. Additive; nothing reads it yet. [done] The new `Profile`
   struct shape was deferred to PR 5 (it name-collides with the existing
   conversation-scoped `Profile`, which is still in use until the cutover); the
   avatar key column is named `encryptionKey` (not `key`) to avoid the SQL
   reserved word and match Android.
3. `profile-table-stores` - three store protocols + GRDB impls + in-memory impls
   + store unit tests (round-trip, events, `claimNextReady` ordering).
4. `profile-table-merge` - `ProfileMerge` + `ProfileDomainEvent` +
   `SelfProfileEdit` + exhaustive merge unit tests (precedence, recency,
   blank-fill, tri-state avatar, verified-kind preservation).
5. `profile-table-repository` - `ProfilesRepository` (cache, read/write,
   `apply`, publishers) + `ProfileBackfill` + repository tests using in-memory
   stores. Still not wired into UI or sync.
6. `profile-table-publisher` - `DBProfilePublishJob` flow already exists from
   PR2/3; add `ProfilePublisher` + `ProfilePublishSession` protocol + the
   MessagingService-side concrete session + durable-queue tests (restart,
   backoff, supersede, stale version).
7. `profile-table-inbound-seam` - rewire `StreamProcessor.processProfile*` to
   `apply(event)`; integration tests (out-of-order, snapshot-vs-update
   precedence) against the Docker node.
8. `profile-table-lifecycle` - SessionManager/MessagingService wiring, backfill
   + warmUp ordering, `ConversationProfileCleaner`, publisher bind/unbind.
   Behind everything reading the new repository.
9. `profile-table-viewmodels` - flip the ViewModels/Views to the repository +
   `ConversationDisplay`; delete `memberContactOverride` and
   `Profile.overlaying`. This is the user-visible cutover; verify on simulator
   (screenshots) against acceptance criteria 1-7.
10. `profile-table-cleanup` - delete `ProfileSyncCoordinator` and dead
    identity-mirroring paths; de-scope `DBMemberProfile` reads.
11. `profile-table-drop-columns` - the gated `dropMemberProfileIdentityColumns`
    migration. Shipped a release after PR9/10 are live so backfill has run for
    all upgraders.

PRs 9 and 11 are the two risk gates; everything before PR9 is invisible to users
and reversible by not landing PR9.

## 13. Backwards and forwards compatibility

The headline: this plan introduces no wire-format changes. Every protobuf in
`profile_messages.proto` (`ProfileUpdate`, `ProfileSnapshot`, `MemberProfile`,
`EncryptedProfileImageRef`) and the app-data `ConversationProfile` /
`EncryptedImageRef` in `conversation_custom_metadata.proto` are untouched. The
refactor changes where identity is stored locally and how it is rendered, not
what is sent between clients. So a mixed-version group works in both directions
and no client needs to upgrade in lockstep.

### Inbound (updated client reads an old client's messages)

Old clients keep sending `ProfileUpdate` / `ProfileSnapshot` exactly as today.
The updated client decodes them with the same codecs; the only change is that the
decoded data is routed through `ProfilesRepository.apply(event)` into `DBProfile`
/ `DBProfileAvatar` instead of `DBMemberProfile`. No existing field is
reinterpreted. In particular, today's avatar semantics are preserved verbatim:

- A `ProfileUpdate` carrying an `encrypted_image` sets the avatar (authoritative).
- A `ProfileUpdate` with no `encrypted_image` clears the avatar (authoritative) -
  the same behavior `StreamProcessor.processProfileUpdate` has today.
- A `ProfileSnapshot` entry fills blanks only and never overwrites a value the
  subject authored - the same "skip if present" behavior, now expressed as the
  merge's `profileSnapshot` precedence level.

### Outbound (old client reads an updated client's messages)

The updated client emits byte-identical `ProfileUpdate` / `ProfileSnapshot`
messages. The `ProfilePublisher` changes durability, ordering, and retry locally;
it does not change the wire bytes. Two outbound channels exist today and both must
be preserved so old clients keep resolving identity:

1. The `ProfileUpdate` message sent to the group.
2. The app-data `ConversationProfile` write into group metadata
   (`group.updateProfile(...)` today).

The publisher's `ProfilePublishSession` must continue to do both. Dropping the
app-data write would regress old clients that read identity from app-data, so it
is a hard requirement, not an optimization.

### Local-only additions (no wire exposure)

`ProfileSource`, the reserved `avatarContentDigest` / `contentDigest` columns, the
`selfProfile` / `profileAvatarSource` / `profilePublishJob` tables, and the merge
machinery are all local. None is serialized into any message. They cannot affect
another client.

### The one wire-affecting improvement, deliberately deferred

The spec's "a name-only update must never blank an avatar" goal is the single
piece that cannot be done without a wire change, and it is out of scope here.
Today "no `encrypted_image` present" is overloaded to mean "clear the avatar," so
there is no way to distinguish a name-only update (should be silent on the avatar)
from an explicit removal (should clear it). Distinguishing them needs a new signal
on the wire - an explicit "avatar removed" tombstone field, distinct from "field
absent." That is a separate, additive, proto3-optional change (a sibling to
ADR 014/015): old clients ignore the new field and fall back to today's behavior,
so it is itself backward compatible. Until it ships, this plan keeps today's exact
semantics (absent image = clear), and the merge engine's `silent` avatar state is
reachable only from snapshot/app-data fill-blank paths, not from `ProfileUpdate`.
This means acceptance criterion 4 (name-only update never blanks an avatar) is
only fully met once that follow-up lands; this plan does not regress it relative
to today.

### Same-version, cross-device (the local user's own installs)

`DBSelfProfile` and the publish queue are per-install local state. A second
install of the same user learns the user's identity the same way any client does:
from the `ProfileUpdate` / app-data the first install publishes. The backfill
seeds `DBSelfProfile` from existing local `DBMemberProfile` rows, so an upgrade in
place does not require a re-publish to recover self identity.

### Upgrade ordering (local, not wire)

The only ordering constraint is local and already covered in Risks: the gated
`dropMemberProfileIdentityColumns` migration (PR 11) must ship a release after the
backfill (PR 5/8) so every upgrader has run the backfill before the legacy columns
disappear. This is a local schema concern with no cross-client effect.

## 14. Testing strategy

- Unit (ConvosCore, macOS, no Docker): models, migration up/down, stores,
  merge engine, repository with in-memory stores, publisher queue mechanics
  (inject a fake `ProfilePublishSession`). Use `.mock` factories per CLAUDE.md.
- Integration (Docker XMTP node): inbound `apply` ordering and snapshot/update
  precedence; publisher send round-trip; backfill from seeded `DBMemberProfile`.
- UI verification (simulator screenshots) for PR9 against acceptance criteria,
  especially: identical avatar across surfaces, removal propagation, name-only
  not blanking avatar, join-group renders members immediately.
- Add the `redundant-decrypt-on-join` counter (spec/ADR 014 gate) as a metric in
  PR8 or PR9 so the digest follow-up has data, without building the digest.

## 15. Risks and rollback

- Backfill correctness is the top risk: keep it idempotent, floor-timestamped,
  and gate the column-drop on its completion marker. If backfill is wrong, no
  data is lost (legacy columns remain until PR11).
- Cutover (PR9) is the visible risk: it is a single PR that can be held or
  reverted independently; everything beneath it is dormant infrastructure.
- Publisher durability: cached ciphertext + `sourceVersion` pin guarantee
  exactly-once-per-conversation, restart-safe sends; covered by queue tests.
- Type-check budget: new SwiftUI bodies must hoist conditionals; review each
  touched body in PR9.

## 16. Open questions (carried from spec)

- Keep the `profileAvatar` FK cascade in addition to the cleaner, or cleaner
  alone. Design keeps both (cascade as defense in depth).
- Whether `DBSelfProfile` subsumes `DBMyProfile` / `MyGlobalProfileRepository`
  or sits alongside during transition. Design: sit alongside through PR9, fold in
  during PR10 cleanup.
- `profileSource` on the row vs derived at apply time. Design: persist on the row
  (`DBProfile.profileSource` / `DBProfileAvatar.profileSource`) so merge
  decisions survive restart without replaying events.
