# Share Extension + Share-Sheet Conversation Suggestions

Status: spike wired + compiling. The ShareExtension target is in the Xcode
project and builds clean for the simulator (send call chain + memory probe
included). Device build is blocked only at code signing: the new App ID needs
its App Groups capability registered (one-time account/portal step, below).

Goal: let users share content from other apps into Convos, with agent
conversations surfacing as one-tap suggestions in the top row of the native
iOS share sheet.

## Two layers

| Layer | What the user sees | Mechanism |
|-------|--------------------|-----------|
| 1. Share target | The Convos icon in the share sheet; tap it -> pick a conversation, send | A Share Extension target (`NSExtensionPointIdentifier = com.apple.share-services`) |
| 2. Conversation suggestions | Actual (agent) conversations as one-tap avatars in the share sheet's top row | Layer 1 + donating `INSendMessageIntent`, + `INSendMessageIntent` in the extension's `IntentsSupported` |

Layer 2 is built on layer 1: tapping a suggestion launches the share extension
pre-targeted to that conversation (read via `extensionContext.intent as? INSendMessageIntent`).

Decisions (locked):
- Target experience: full suggestion row (layer 1 + intent donation).
- Send strategy: hybrid - enqueue to an outbox for reliability, then attempt an
  in-extension publish; the main app finishes any send the extension could not.
- Outbox storage: reuse `DBMessage` rows with `status = .unpublished` (no separate table).

## What already exists (reuse, do not rebuild)

The Notification Service Extension already boots `ConvosCore` in a second
process against shared state. A share extension inherits all of it:

- App Group `group.org.convos.ios{,-preview,-local,-preview.pr}` - home of the
  shared GRDB DB (`convos-single-inbox.sqlite`, multi-process WAL) and the
  shared `UserDefaults` suite.
- Keychain access group `FY4NZR34Z3.group.org.convos.ios*` - holds the XMTP
  identity; an extension in the same group loads it.
- Bundle-ID / xcconfig pattern - mirror `NOTIFICATION_SERVICE_BUNDLE_ID`
  (`$(MAIN_BUNDLE_ID).ConvosNSE`) with `SHARE_EXTENSION_BUNDLE_ID`
  (`$(MAIN_BUNDLE_ID).ShareExtension`) across Local/Dev/Prod/PR xcconfigs.
- Environment reconstruction in-extension: `NotificationExtensionEnvironment.getEnvironment()`
  reads the `AppEnvironment` the main app stored in the shared keychain.

Boot ingredients (from `ConvosClient+App.swift:6` and the NSE):
`DatabaseManager(environment:)`, `KeychainIdentityStore(accessGroup:)`,
`SessionManager(...)`, `PlatformProviders.iOSExtension`
(`ConvosCoreiOS.swift:65` - mock lifecycle/device/push; no `backgroundUploadManager`
or oauth, which is fine for text and matters only for attachments).

Gotcha carried over from the NSE (`NotificationService.swift:16-34`): keep
libxmtp logging OFF in the extension. Enabling it triggers a `tracing-oslog`
Rust panic that kills the process before it can do its work.

## Send path (all primitives confirmed to exist)

```
ConvosClient.client(environment:, platformProviders: .iOSExtension, coreActions: NoOpCoreActions())
  -> client.session.messagingService()            // SessionManager.swift:570 -> AnyMessagingService
  -> messagingService().messageWriter(for: ...)   // MessagingService.swift:224 -> OutgoingMessageWriterProtocol
  -> writer.send(text:)                            // OutgoingMessageWriter.swift:364
       internally: messageSender(for: conversationId).prepare(text:) -> saves DBMessage(.unpublished) -> publish()
```

Durable-publish primitive for the flush coordinator:
`messageSender(for: conversationId).publishMessage(messageId:)`
(`XMTPClientProvider.swift:15`). Prepared messages live durably in libxmtp's
store, so a freshly-resolved sender in any process publishes them by id - this
is exactly what the existing manual-retry path does
(`OutgoingMessageWriter.swift:2690 -> 2776`).

## The required new piece: a flush coordinator

Verified (read-only sweep of `OutgoingMessageWriter`, `SessionManager`,
`SyncingManager`): there is NO automatic re-publish of `.unpublished` rows.

- `MessageStatus` = `unpublished | published | failed | unknown`
  (`Models/MessageStatus.swift`).
- `OutgoingMessageWriter` holds publish work only in its in-memory actor
  `messageQueue`. If the process dies after the `.unpublished` row is written
  but before `sender.publish()`, the row is stranded.
- The only recovery today is the user manually tapping retry on a `.failed`
  message; that path filters on `.failed`, not `.unpublished`.
- `SessionManager` foreground/inbox-ready and `SyncingManager` pull INCOMING
  messages only; neither scans outgoing `.unpublished` rows.

So reusing `DBMessage` requires building, in the main app: a coordinator that on
inbox-ready / foreground scans `.unpublished` rows and publishes them.

Natural hook: alongside the foreground observer in
`SessionManager.swift:182-205` (the same place `runStaleStrangerGC` is kicked).

### Correctness: avoid double-send (the core hybrid problem)

Two publishers exist (the extension's optimistic attempt, and the app's flush).
A row can be in one of three states when the app next runs:

1. Text persisted, never prepared in libxmtp (extension could not boot a client).
   -> flush must re-prepare from `text` via the normal `send`/`prepare+publish`
   path. `publishMessage(messageId:)` will not work (nothing in libxmtp's store).
2. Prepared in libxmtp, not published (crash/timeout between prepare and publish).
   -> flush publishes by id: `publishMessage(messageId: row.id)`. Cheap, no re-encrypt.
3. Published, but the `.unpublished -> .published` status write never landed
   (crash right after publish). -> re-publishing would duplicate the message on
   the network.

Design implications to resolve during implementation:
- Distinguish state 1 from state 2 with a column/flag the extension sets when
  `prepare` succeeds (e.g. a `preparedInLibXMTP` bool, or rely on `id` being the
  libxmtp message id vs. a client UUID).
- The flush must "claim" a row (status transition guarded in a single write
  transaction) so two flush passes / app+extension do not both publish.
- State 3 (publish succeeded, status write lost) is the residual duplicate risk.
  libxmtp's `publishMessage` idempotency by message id is the mitigation to
  verify; if it is idempotent, re-publishing the same prepared id is a no-op.

## Memory feasibility (the spike's purpose)

Share extensions have a hard 120 MB ceiling (EXC_RESOURCE). Strong precedent
that this is fine: the NSE already boots the XMTP client and decrypts MLS within
the 24 MB NSE budget in production. Publish reuses the loaded MLS group state
plus a network send; 120 MB is 5x the proven-sufficient NSE budget.

The spike measures `os_proc_available_memory()` across boot -> prepare ->
publish on-device/sim to confirm headroom and latency. Code: `ShareExtension/ShareViewController.swift`.

## Suggestions + teardown risk (track with App-Intents indexing work)

Donate `INSendMessageIntent` (recipients as `INPerson` + decrypted avatar as
`INImage`, `conversationIdentifier = Conversation.id`, group name = conversation
name) from the main app's `OutgoingMessageWriter` send path and after a
successful extension send, biased toward agent conversations
(`Conversation.members.contains { $0.isAgent }`).

The suggestion row is system-ranked, not declarative: donating makes agent
conversations eligible/likely, not pinned.

Teardown caveat: when a user leaves / is removed from a conversation, stale
donations would keep surfacing a dead conversation in the share sheet. Per the
"removed-from-group zombie conversation" bug, removal is only handled in-memory
and resurrects on restart - so donation teardown is unreliable for the same
reason. This is the same teardown-lifecycle problem flagged for the App-Intents
message-search indexing feature; track them together.

## Wiring the target (done programmatically)

The target was added with the `xcodeproj` gem (script:
`Scripts/add_share_extension_target.rb`, idempotent - re-run to regenerate),
mirroring the NotificationService target:

- product type app-extension, 4 configs (Dev/PR Preview/Local/Release) each
  with the matching base xcconfig (Dev->Dev, PR Preview->PR, Local->Local,
  Release->Prod), `PRODUCT_BUNDLE_IDENTIFIER = $(SHARE_EXTENSION_BUNDLE_ID)`,
  `INFOPLIST_FILE` / `CODE_SIGN_ENTITLEMENTS` pointing at `ShareExtension/`.
- local SPM product deps `ConvosCore` + `ConvosCoreiOS`.
- embedded in the Convos app's "Embed Foundation Extensions" phase + added as
  an app target dependency.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = NO` on this target only (spike concession;
  flip back before shipping).
- a shared `ShareExtension` scheme for building the extension in isolation.

Signing per config mirrors the app/NSE: Dev + Local = Automatic (team
FY4NZR34Z3), Release + PR Preview = Manual.

## Validation results

- Simulator build (`-scheme ShareExtension -sdk iphonesimulator`,
  Local config): BUILD SUCCEEDED, zero errors/warnings. Confirms the send
  call chain, `os_proc_available_memory()` probe, and target wiring compile.
- Device build (`-destination generic/platform=iOS -allowProvisioningUpdates`):
  fails at the provisioning gate (before compile) with:
    - `No Accounts: Add a new account in Accounts settings`
    - `Provisioning profile ... doesn't include the App Groups capability`
    - `... doesn't support the group.org.convos.ios-local App Group`
  i.e. Automatic signing could not register the new App ID's App Groups
  capability from a headless build with no signed-in account.

### The one remaining device-signing step (account/portal, done by a human)

The existing app + NSE device-build fine because their App IDs already have the
app group registered. The new `org.convos.ios{,-preview,-local,-preview.pr}.ShareExtension`
App IDs do not yet exist with the App Groups capability. Either:

- Open the project in Xcode (signed-in account) and build to a device once -
  Automatic signing registers the App ID and adds the `group.org.convos.ios-*`
  App Group to it; or
- Register the App IDs + App Group capability in the developer portal (and add
  `match` profiles) for device/TestFlight.

App Groups work on the simulator with no profiles, so the memory spike can run
on a sim build with no portal work at all.

## Spike runbook (get the memory number)

1. Wire the target (above) for the Local scheme; build for an arm64 simulator.
2. Use a simulator with a logged-in account that has at least one conversation.
3. From any app (e.g. Notes/Safari), share text -> Convos -> Post.
4. Read results from the shared log: `<app-group-container>/Logs/convos.log`
   (grep `ShareSpike`). Lines report available-memory at boot, after client
   boot, after prepare, after publish, plus wall-clock per stage.
5. Pass criteria: available memory never approaches 0 (stays well above the
   point where iOS jetsams at 120 MB footprint) and total time is within the
   share-extension budget.

## Open implementation questions

- Distinguish prepared vs. text-only `.unpublished` rows (state 1 vs 2 above).
- Confirm `publishMessage(messageId:)` idempotency to close the state-3 duplicate risk.
- Attachment sends need `backgroundUploadManager`, which `.iOSExtension`
  providers omit; text-first for v1, attachments need a provider story.
- Avatar decryption for `INImage` (encrypted via salt/nonce/key on `Conversation`)
  - fetch + decrypt + cache; donation is async/best-effort so this is tolerable.
