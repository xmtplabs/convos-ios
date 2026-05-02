# HealthKit Background Subscriptions

**Status**: Plan, not yet implemented
**Companion docs**: [`capability-resolution.md`](https://github.com/xmtplabs/convos-ios/blob/dev/docs/plans/capability-resolution.md), [`connections-v1-prd.md`](https://github.com/xmtplabs/convos-ios/blob/dev/docs/plans/connections-v1-prd.md)

## Problem

HealthKit cannot be queried from the Notification Service Extension. The NSE has no HealthKit entitlement, `HKHealthStore` requires the host-app authorization context, and iOS only delivers background HealthKit updates to the **main app process**. Any architecture that imagines an agent saying "fetch yesterday's steps" in a message and the device pulling on the spot is unworkable: when the message arrives, the host app may not be running.

The on-demand action shape (`fetch_summary_last_24h`, `fetch_samples`) bakes that assumption in. Reliable HealthKit delivery on iOS requires a different shape: the agent **declares interest**, iOS owns the **wake-up cadence**, and the app **routes deltas** to subscribed conversations.

## Model

After a user grants HealthKit for a conversation, two streams flow into the conversation:

1. **Initial backfill** — one `ConnectionPayload` at subscribe time, holding samples from the last *N* days for the requested `HKObjectType`. Default 7 days, agent-overridable.
2. **Background deltas** — a `ConnectionPayload` per (conversation × type) every time iOS wakes us with new samples. The agent declares each subscription with a `subscribe_background_delivery` action; the app runs an `HKObserverQuery` per type and emits anchored deltas to every conversation subscribed to that type.

The agent never queries on demand. It states what it cares about once, and the system pushes data when iOS says new data exists.

## Wire format — no new content types

Three existing content types cover everything:

| Content type | Direction | Used for |
|---|---|---|
| `ConnectionInvocation` (`convos.org/connection_invocation/1.0`) | Agent → device | The `subscribe_background_delivery` and `unsubscribe_background_delivery` action calls |
| `ConnectionInvocationResult` | Device → agent | Ack of subscribe/unsubscribe |
| `ConnectionPayload` | Device → conversation | Backfill snapshots and per-wake deltas (`HealthBody` for both — same shape, different windows) |

No protocol bump, no new codec. The agent discovers the new actions through the existing `ActionSchema` manifest the moment they're added to `HealthActionSchemas.all`.

## New action schemas

```swift
public static let subscribeBackgroundDelivery = ActionSchema(
    kind: .health,
    actionName: "subscribe_background_delivery",
    capability: .read,
    summary: "Register for ongoing HealthKit deltas of one object type. The first response is a backfill of the last `historyDays` of samples; subsequent deliveries arrive whenever iOS wakes the app with new data for that type.",
    inputs: [
        ActionParameter(name: "typeIdentifier", type: .enumValue(allowed: SupportedHealthTypes.allowedIdentifiers), description: "HealthKit object-type identifier (e.g. HKQuantityTypeIdentifierStepCount).", isRequired: true),
        ActionParameter(name: "frequency",      type: .enumValue(allowed: ["immediate", "hourly", "daily", "weekly"]), description: "Background-delivery cadence requested. iOS may deliver less frequently; `immediate` only applies to types that support it.", isRequired: true),
        ActionParameter(name: "historyDays",    type: .int, description: "Bootstrap window in days (1–90). Defaults to 7.", isRequired: false),
    ],
    outputs: [
        ActionParameter(name: "subscriptionId", type: .string, description: "Stable id for this (conversation × type) subscription.", isRequired: true),
        ActionParameter(name: "backfillSampleCount", type: .int, description: "Number of samples included in the initial backfill payload.", isRequired: true),
    ]
)

public static let unsubscribeBackgroundDelivery = ActionSchema(
    kind: .health,
    actionName: "unsubscribe_background_delivery",
    capability: .read,
    summary: "Stop background deltas for a previously-subscribed object type.",
    inputs: [
        ActionParameter(name: "typeIdentifier", type: .enumValue(allowed: SupportedHealthTypes.allowedIdentifiers), description: "HealthKit object-type identifier.", isRequired: true),
    ],
    outputs: []
)
```

`SupportedHealthTypes.allowedIdentifiers` is a curated list of the `HKObjectType` identifiers we ship support for. New types ship by adding them there plus mapping logic in `HealthSampleMapping`.

`historyDays` is per-type because each subscribe call carries exactly one type. An agent that wants 30 days of sleep and 7 days of steps issues two subscribe calls.

## App-side pieces

| Piece | Location | Responsibility |
|---|---|---|
| **Schema entries** | `HealthActionSchemas` | Declare the two new actions in `.all` so they appear in the capability manifest. |
| **Subscription registry** | New GRDB table next to `EnablementStore` | Rows keyed by `(conversationId, agentInboxId, typeIdentifier)` storing `frequency`, `historyDays`, observer-query `anchor`, `createdAt`. |
| **Subscribe handler** | `HealthDataSink` (or sibling `HealthBackgroundSubscriptionManager`) | Decode invocation → resolve `HKObjectType` → run anchored backfill query for `historyDays` → emit `ConnectionPayload` (backfill) → call `HKHealthStore.enableBackgroundDelivery(for:frequency:)` (idempotent per type) → register `HKObserverQuery` if not already running for the type → insert subscription row → ack via `ConnectionInvocationResult`. |
| **Unsubscribe handler** | Same | Delete row → if no remaining rows for the type across all conversations, `disableBackgroundDelivery(for:)` and tear down the observer → ack. |
| **Observer registrar** | App-launch / sync bootstrap | Read all subscription rows. Group by `typeIdentifier`. For each unique type, register one `HKObserverQuery`. On observer fire: anchored object query from saved anchor → for each conversation subscribed to that type, emit a `ConnectionPayload(HealthBody.delta)` → advance per-(conversation, type) anchor. |

The registry is the source of truth. If the user uninstalls and reinstalls, the registry rebuilds from local storage; if the local store is lost, agents resubscribe (their prompt-side context tells them to). This matches how `EnablementStore` behaves today.

## Routing — one message per subscription

A "subscription" is the row `(conversationId, agentInboxId, typeIdentifier)`. When iOS wakes us with deltas for a type, we loop the rows for that type and send one `ConnectionPayload` per row. We do not batch across types and we do not batch across conversations.

**Example.** Wake-up at noon. New step samples and new HRV samples arrived since the last wake. Conversation A's agent is subscribed to steps. Conversation B's agent is subscribed to steps and HRV.

- A receives 1 message: steps delta.
- B receives 2 messages: steps delta, HRV delta.

This keeps the agent prompt simple (one type per inbound message, one conversation per inbound message) and lets anchors advance independently per (conversation, type).

Background-delivery payloads are sent with `shouldPush = false` so iOS doesn't fire a user notification on every observer wake.

## Frequency aggregation

`HKHealthStore.enableBackgroundDelivery(for:frequency:)` is **global per type**, not per subscriber. Two conversations subscribing to step count at different frequencies cannot get different cadences from iOS.

The registry tracks the per-conversation frequency for routing context, but the call to `enableBackgroundDelivery` uses the **most aggressive** frequency among current subscribers, where `immediate > hourly > daily > weekly`. When a subscription is added or removed, the registrar recomputes the effective frequency and re-calls `enableBackgroundDelivery` if it changed.

`immediate` is only honored by iOS for types tagged for it (a narrow set of quantity types). For unsupported types the system silently downgrades to `hourly`. This is fine — we report the requested frequency to the agent, and iOS does whatever it does.

## What happens to the existing fetch actions

`fetch_summary_last_24h` and `fetch_samples` keep working but become **best-effort**. We update their schema descriptions to say:

> Best-effort. The device only responds when the host app is reachable to run a HealthKit query. For durable, ongoing data flow, use `subscribe_background_delivery`.

The agent's planner should treat subscriptions as the primary mechanism. We don't deprecate the fetch actions in this PR because:

1. They're still useful for one-off ad-hoc ranges the agent would never want subscribed.
2. They land via the same wire path; cost to keep is zero.

If the host app is foregrounded when an invocation arrives, the existing `HealthDataSink` answers it normally. If not, the `XMTPInvocationListener` enqueues it; on next foreground we attempt and either complete it or expire it.

## Open considerations

- **Anchor durability across reinstall.** Anchors are HealthKit's local cursor. After a reinstall, the agent should resubscribe and we re-issue a backfill from scratch. We don't try to migrate anchors out-of-band.
- **`historyDays` upper bound.** Cap at 90. An agent asking for "everything since 2014" can stall the device on the first response and consume large XMTP payloads.
- **Quiet hours.** Out of scope for v1 — agents that subscribe to `immediate`-frequency types may post deltas overnight. Quiet-hours muting can layer on top later via the same mechanism that mutes other ambient assistant chatter.
- **Cross-device coordination.** A user with two devices both running Convos may emit duplicate deltas in the same conversation. We address this when multi-device support lands; for v1 the registry is local per device.
- **Observer-query lifecycle.** `HKObserverQuery` survives across launches once `enableBackgroundDelivery` is on. We rebuild observers on launch to keep the in-memory list of completion handlers, but iOS will wake the app even if we forget — the registrar must be defensive about queries firing before subscriptions are loaded.

## Implementation order

1. Add `subscribe_background_delivery` and `unsubscribe_background_delivery` to `HealthActionSchemas`. Curated `SupportedHealthTypes` list.
2. GRDB migration + repository for `health_background_subscriptions`.
3. `HealthBackgroundSubscriptionManager` with subscribe/unsubscribe handlers + the per-type aggregation logic for `enableBackgroundDelivery`.
4. Backfill query path — emits `ConnectionPayload` synchronously on subscribe, ack after.
5. Observer registrar — runs on app launch, registers observers, dispatches to per-row anchored queries on fire, fans out one `ConnectionPayload` per subscription.
6. Tests:
   - Unit: aggregation picks max frequency; row removal disables background delivery when last sub leaves.
   - Integration: subscribe → confirm backfill payload size matches `historyDays`; sample injected → observer fires → exactly one `ConnectionPayload` per subscribed conversation; unsubscribe → no further deltas.
7. Update agent prompt / capability manifest documentation to describe the subscribe-first model.
