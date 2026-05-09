# ConvosConnections — XMTP Adapter Layer

**Status**: Ready for implementation
**Owner**: @yewreeka
**Related**: [`connections-write-capabilities.md`](./connections-write-capabilities.md)

## Goal

Bridge the transport-agnostic `ConvosConnections` package to XMTP as the first (and, for the foreseeable future, only) transport. Agents send writes as XMTP messages; devices emit sensor payloads as XMTP messages; outcomes travel back as XMTP messages. All three directions use custom content types registered with the XMTP client.

## Non-Goals

- Changing the `ConvosConnections` package itself. This PRD is purely additive from that package's perspective.
- Changing Convos's existing message streaming pipeline. The adapter provides pure functions; `SyncingManager` stays untouched.
- XMTP content-type standardization, cross-app reuse, or inclusion in an XMTP XIP. Namespace is `convos.org/*` (matching existing Convos custom codecs); Convos is the only consumer.
- Support for multiple schema versions simultaneously. v1 is the only version that executes; anything else returns structured failure.

## User Stories

- As Convos, I want to register our three custom content codecs at app startup so that agent-to-device messages decode into strongly-typed `ConnectionInvocation` values.
- As an agent author, I want to send a `ConnectionInvocation` over XMTP and receive a `ConnectionInvocationResult` back on the same conversation so I can observe success/failure without polling.
- As Convos, I want to hand an incoming decoded XMTP message to the adapter and have it route through the existing `ConnectionsManager` gating chain so I don't have to re-implement capability checks.
- As Convos, I want the adapter to refuse messages with unknown schema versions and reply with a structured error instead of silently dropping them.

## Architecture

### Placement

The adapter lives as a new target in `ConvosCore/Package.swift`, **not** in `ConvosConnections/Package.swift`. This pins `xmtp-ios` (via `libxmtp`) in one place — ConvosCore — and avoids two-Package.swift version drift.

```
ConvosCore/
  Package.swift                           # existing libxmtp / XMTPiOS pin
  Sources/
    ConvosCore/                           # existing
    ConvosCoreiOS/                        # existing
    ConvosConnectionsXMTP/                # NEW
      Codecs/
        ConnectionPayloadCodec.swift
        ConnectionInvocationCodec.swift
        ConnectionInvocationResultCodec.swift
      Delivery/
        XMTPConnectionDelivery.swift
      Listener/
        XMTPInvocationListener.swift
      Bootstrap/
        ConvosConnectionsXMTP.swift       # register-all convenience
  Tests/
    ConvosConnectionsXMTPTests/
```

Package.swift grows one sibling path dependency:

```swift
.package(path: "../ConvosConnections"),
```

and one new target depending on `XMTPiOS` + `ConvosConnections`.

### Three content types

| Content type ID                                  | Swift type                     | Direction        |
|--------------------------------------------------|--------------------------------|------------------|
| `convos.org/connection_payload/1.0`              | `ConnectionPayload`            | device → agent   |
| `convos.org/connection_invocation/1.0`           | `ConnectionInvocation`         | agent → device   |
| `convos.org/connection_invocation_result/1.0`    | `ConnectionInvocationResult`   | device → agent   |

Each codec:
- Encodes via `JSONEncoder` into `EncodedContent.content`
- Sets `fallback` to a short plain-text line: `"Connection event"` / `"Connection invocation"` / `"Connection result"` — no emoji, no summary, not meant to appear as a chat bubble
- Sets `shouldPush = false` — agent writes aren't notification-worthy on their own; the host UI decides what to surface

Registration happens by adding the codec instances to `ClientOptions(codecs: [...])` when Convos constructs the client — the adapter exposes a `ConvosConnectionsXMTP.codecs()` helper returning the three instances to merge into the host's existing list.

### Delivery adapter — `XMTPConnectionDelivery`

Conforms to `ConnectionDelivering`. Two methods:

```swift
func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws
func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws
```

Implementation:
- Looks up the `XMTPiOS.Conversation` by id via a provided `ConversationLookup` closure (Convos supplies this — GRDB-backed, matches existing patterns)
- Calls `conversation.send(content: value, options: SendOptions(contentType: codec.contentType))`
- Throws `ConnectionDeliveringError` variants on lookup failure / send failure — existing error type in `ConvosConnections`, no new errors needed

### Listener — `XMTPInvocationListener`

**Pure function, no subscription.** This is the key design choice that avoids colliding with PR 713's `SyncingManager` work.

```swift
public final class XMTPInvocationListener {
    init(manager: ConnectionsManager, delivery: XMTPConnectionDelivery)

    /// Call this from wherever Convos already receives decoded messages.
    /// No-ops if the message's content type isn't ConnectionInvocation.
    func processIncoming(message: XMTPiOS.DecodedMessage, conversationId: String) async
}
```

Routing inside `processIncoming`:
1. If `message.encodedContent.type` != `ConnectionInvocationCodec.contentType` → return (no-op).
2. Decode. Decode failure → log, return (the codec threw, can't even reply with a structured error since we don't have an invocationId).
3. **Schema version gate**: if `invocation.schemaVersion > ConnectionInvocation.currentSchemaVersion`, skip the manager entirely and deliver a synthetic `ConnectionInvocationResult(status: .executionFailed, errorMessage: "unsupported schema version X")` directly via the delivery adapter. Do not call `manager.handleInvocation` — the sinks can't be trusted to reject unknown fields gracefully.
4. Otherwise: `manager.handleInvocation(invocation, from: conversationId)`. The manager's 6-step chain takes it from there; the result auto-delivers through the same `XMTPConnectionDelivery`.

### Bootstrap

One file, one function:

```swift
public enum ConvosConnectionsXMTP {
    /// Merge these into `ClientOptions(codecs: [...])` at client construction time.
    public static func codecs() -> [any ContentCodec] {
        [
            ConnectionPayloadCodec(),
            ConnectionInvocationCodec(),
            ConnectionInvocationResultCodec(),
        ]
    }
}
```

Host code (in `InboxStateMachine` or wherever `ClientOptions` is built) appends `ConvosConnectionsXMTP.codecs()` to the existing codec list. Constructing `XMTPConnectionDelivery` + `XMTPInvocationListener` is left to the host (needs client access and conversation lookup).

## Decisions (locked in)

1. **Namespace**: `convos.org/connection_*/1.0` — matches every other custom codec in ConvosCore (`convos.org` authority, snake_case typeID). Convos is the only consumer; no cross-app reuse planned.
2. **Fallback content**: plain strings (`"Connection event"`, `"Connection invocation"`, `"Connection result"`). No emoji. The real UI rendering for payloads is TBD and will be decided separately — likely rendered as system/group-update style rather than chat bubbles.
3. **Schema version mismatch**: synthesize a `ConnectionInvocationResult` with `status: .executionFailed` and `errorMessage: "unsupported schema version N"`, deliver it on the same conversation, never call a sink. Agents interpret this as "fallback to a simpler tool" or "retry when the client upgrades."
4. **Package placement**: inside ConvosCore's Package.swift, not ConvosConnections. Keeps xmtp-ios pinning in one place.
5. **Inbound message handling**: pure function (`processIncoming`), not a parallel subscription. Convos calls it from wherever it already dispatches decoded messages. Avoids PR 713 collision.

## Security posture

No new surface. The manager already owns the access model:
- Capability gate on `(kind, capability, conversationId)` — user consent per verb per conversation
- Authorization gate — the sink checks iOS-level permission
- Always-confirm gate — host presents UI when enabled

The listener doesn't need to authenticate senders: XMTP messages are signed at the transport layer, and the conversation id is the authenticator ("the user enabled create_contact for THIS conversation"). An unauthorized sender gets `capabilityNotEnabled` back, same as any other rejection.

## Failure modes

| Scenario                                          | Behavior                                                    |
|---------------------------------------------------|-------------------------------------------------------------|
| Unregistered codec at decode time                 | XMTP surfaces `UnknownContentTypeError`; host logs, no result delivered |
| Listener receives content that isn't our type     | No-op, returns immediately                                  |
| Schema version mismatch                           | Synthetic `executionFailed` result delivered on same conversation |
| Decode fails for a ConnectionInvocation content type | Log the error; cannot reply (no invocationId). Delivery observer is not invoked. |
| `XMTPConnectionDelivery.deliver` can't find conversation | Throws `ConnectionDeliveringError.conversationNotFound`; manager records via `deliveryObserver.connectionInvocation(didFailDelivery:)` |
| `conversation.send` fails                         | Same observer path; invocation log retains the error string |

## v1 Success Criteria

- [ ] ConvosCore's Package.swift has a `ConvosConnectionsXMTP` target depending on `../ConvosConnections` + XMTPiOS
- [ ] Three content codecs with round-trip JSON encoding and `fallback` set to plain strings
- [ ] `XMTPConnectionDelivery` implements both `deliver` methods of `ConnectionDelivering`
- [ ] `XMTPInvocationListener.processIncoming` routes valid v1 invocations to `ConnectionsManager.handleInvocation` and delivers results via `XMTPConnectionDelivery`
- [ ] Schema version mismatch delivers a synthetic `executionFailed` result and does not call any sink
- [ ] Content types don't push (`shouldPush: false`)
- [ ] Bootstrap: `ConvosConnectionsXMTP.codecs()` returns the three instances for merging into `ClientOptions`
- [ ] Unit tests:
  - Codec round-trip for all three types (JSON encode → `EncodedContent` → decode)
  - Listener ignores non-ours content types
  - Listener delivers `executionFailed` on schema version mismatch and never touches the manager
  - Listener forwards valid invocations to a spy manager
  - Delivery adapter calls the provided conversation-lookup closure

## Out of scope (future PRs)

- Actual Convos integration: calling `register()`, instantiating delivery + listener with a GRDB-backed conversation lookup, hooking `processIncoming` into the message pipeline. Lands after PR 713 as a small stacked PR.
- UI for rendering `ConnectionPayload` in the conversation timeline (system/group-update style).
- A schema version 2 migration story (how to deprecate fields, add new ones).
- Cross-client compatibility tests against a non-Convos XMTP client.

## Risks

- **XMTPiOS API shape**: the `ContentCodec` protocol and `EncodedContent` surface in the pinned `ios-4.9.0-dev.88ddfad` revision — implementation needs to verify method signatures (`encode`, `decode`, `fallback`, `shouldPush`) match what's documented. Not expected to change, but should be checked before writing the codecs.
- **Version skew with agents**: agents running ahead of the device's schema version will hit the mismatch path. Acceptable for v1 because we control both sides; document the failure mode.
- **Post-713 integration friction**: if PR 713 changes how Convos dispatches decoded messages, the `processIncoming` wiring will need to follow. Low risk because the adapter is a pure function with no subscription.
