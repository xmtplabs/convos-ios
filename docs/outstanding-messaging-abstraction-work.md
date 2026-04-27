# Outstanding Messaging-abstraction work

After the migration off `XMTPClientProvider` onto `MessagingClient`, ConvosCore's domain layer no longer reaches for XMTPiOS types directly except in four bounded zones, each with a known unblock condition. This document is the punch list of what's left and why.

Each item below is referenced from the codebase as `// FIXME: see docs/outstanding-messaging-abstraction-work.md#<anchor>` so a reader at the call site can find the rationale without re-deriving it.

---

## codec-migration

**The XMTP content codecs (`ReadReceipt`, `Reply`, `Reaction`, `ExplodeSettings`, `Attachment`, `RemoteAttachment`, `MultiRemoteAttachment`, `JoinRequest`, `InviteJoinError`, `ProfileUpdate`, `ProfileSnapshot`, `AssistantJoinRequest`, `TypingIndicator`, `GroupUpdated`) are still typed against XMTPiOS's `ContentCodec`** — they live in the XMTPiOS codec registry and produce XMTPiOS-typed `EncodedContent` payloads. Writers that need to produce / interpret these payloads currently bridge through the XMTPiOS adapter (`underlyingXMTPiOSConversation` / `underlyingXMTPiOSGroup` / `underlyingXMTPiOSDm`).

**Unblock condition:** introduce a `MessagingCodec` protocol on the abstraction (already declared in `ConvosMessagingProtocols.MessagingCodec` but not yet adopted by Convos's custom codecs). Each codec then ships an XMTPiOS adapter that conforms to both `MessagingCodec` and `XMTPiOS.ContentCodec`. Once that lands, writer call sites stop downcasting to the XMTPiOS adapter.

**Affected files:**
- `ConvosCore/Storage/Writers/ReadReceiptWriter.swift:43`
- `ConvosCore/Storage/Writers/MyProfileWriter.swift:191`
- `ConvosCore/Storage/Writers/ReplyMessageWriter.swift:95`
- `ConvosCore/Messaging/InlineAttachmentRecovery.swift:3`
- `ConvosCore/Messaging/RemoteAttachmentLoader.swift:3`
- `ConvosCore/Messaging/PhotoAttachmentService.swift:3`
- `ConvosCore/Messaging/Abstraction/XMTPiOSAdapter/DBBoundary/XMTPiOSConversationWriterSupport.swift` (8 separate per-op bridges: `sendReadReceipt`, `sendTextReply`, `sendReaction`, `sendExplode`, `encodeEncryptedAttachment`, `prepareText`, `prepareRemoteAttachment`, `ProfileSnapshotBridge.sendSnapshot`, `ProfileSnapshotBridge.sendProfileUpdate`)
- `ConvosCore/Inboxes/InboxStateMachine.swift:7` — `defaultXMTPCodecs()` returns `[any XMTPiOS.ContentCodec]`; the codec list source is XMTPiOS-typed and used at client-creation time
- `ConvosCore/Messaging/Protocols/MessagingClientFactory.swift:3` — the factory protocol's `xmtpCodecs` parameter takes `[any XMTPiOS.ContentCodec]`. Once the codecs ship as `MessagingCodec`, this parameter changes type and the factory's import drops.

---

## identity-secp256k1

**`KeychainIdentityKeys.signingKey` returns `XMTPiOS.PrivateKey` (a secp256k1 wrapper),** because Convos doesn't ship a first-party secp256k1 implementation. Auth code paths that produce or consume signing keys reach for the XMTPiOS type.

**Unblock condition:** Convos publishes a first-party secp256k1 wrapper (or adopts an external Swift secp256k1 lib like `swift-secp256k1`) and `MessagingSigner` is the only public surface for signing. The XMTPiOS-side `XMTPiOSMessagingSigner` adapter then becomes a thin bridge that converts the Convos type into whatever XMTPiOS needs for `Client.create(account:)`.

**Affected files:**
- `ConvosCore/Auth/Keychain/KeychainIdentityStore.swift:6`
- `ConvosCore/Auth/MockAuthService.swift:5`

---

## factory-clientoptions-api

**`XMTPAPIOptionsBuilder.build(...)` returns `XMTPiOS.ClientOptions.Api`**, used by the static-op build path. The shape leaks the XMTPiOS type to anyone who needs an API endpoint configuration before the messaging client itself is built.

**Unblock condition:** introduce a backend-agnostic `MessagingClientConfig.Endpoint` (or similar) that carries the same fields (`env`, `isSecure`, `appVersion`) and have the XMTPiOS factory translate at the boundary.

**Affected files:**
- `ConvosCore/Inboxes/XMTPAPIOptionsBuilder.swift:3`
- `ConvosCore/Messaging/Protocols/MessagingClientFactory.swift:3` (this file is also referenced under `codec-migration`; the same import covers both reasons)

---

## stream-wire-layer

**The wire-layer streaming seam still passes raw `XMTPiOS.Group` and `XMTPiOS.DecodedMessage` values into `StreamProcessor`.** This is because the XMTPiOS `Conversations.streamAll(...)` API yields concrete XMTPiOS types and the writer pipeline bridges back into the abstraction at the `processConversation` / `processMessage` entry points.

`SyncingManager` short-circuits for non-XMTPiOS clients today via the polling shim added during the DTU streaming work — see `ConvosCoreDTU/Sources/ConvosCoreDTU/DTUMessagingGroup.swift` `streamMessages` and `DTUStreamSupport.swift`. The DTU lane gets messages via polling; the XMTPiOS lane gets them via the native stream. Both flow into the same `StreamProcessor` overloads.

**Unblock condition (any of):**
1. Lift `StreamProcessor.processConversation` / `processMessage` overloads onto `any MessagingGroup` / `any MessagingMessage`. Backends provide their own streams; the processor stops caring.
2. Add a native-handle escape hatch on `MessagingMessage` (analogous to `MessagingConversation.underlyingXMTPiOSConversation`) so the processor can keep its XMTPiOS-typed core but accept abstraction-typed inputs.
3. Move the stream-iteration loops into the XMTPiOS adapter and have it yield `MessagingMessage` directly — the cleanest endpoint, but the largest refactor.

**Affected files:**
- `ConvosCore/Syncing/StreamProcessor.swift:7`
- `ConvosCore/Syncing/SyncingManager.swift:5`
- `ConvosCore/Syncing/InviteJoinRequestsManager.swift:6` — DM back-channel reads pass XMTPiOS-typed messages into ConvosInvites' invite-join request handler
- `ConvosCore/Inboxes/MessagingService+PushNotifications.swift:8` — NSE chain decodes XMTPiOS push payloads
- `ConvosCore/Inboxes/ConversationStateMachine.swift:7` — receives a freshly-created `MessagingGroup` from `newGroupOptimistic()` and bridges into the XMTPiOS-typed `streamProcessor.processConversation`

---

## How to retire an entry

1. Pick one of the four themes above.
2. Implement the unblock condition.
3. Remove the inline `// FIXME: see docs/outstanding-messaging-abstraction-work.md#<anchor>` from each affected file.
4. Drop the `@preconcurrency import XMTPiOS` line.
5. Strike the section here once all entries are retired.

Each theme is independently retirable — they don't share a critical path.
