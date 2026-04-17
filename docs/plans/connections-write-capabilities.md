# ConvosConnections Write Capabilities

> **Status**: Ready for architect
> **Created**: 2026-04-16
> **Stacked on**: ConvosConnections read layer (PR 713 single-inbox refactor)

## Overview

Add a reverse channel to `ConvosConnections` so that an agent's message can trigger an action on the user's device — starting with Calendar writes. The existing package already moves data from device to agent (read). This work moves intent from agent to device (write).

## Problem Statement

`ConvosConnections` today is one-directional: the user's Calendar, Health, Location, and other sources emit payloads that agents consume. Agents can observe but cannot act. That is fine for passive awareness, but Convos is moving toward AI assistants that help users get things done. An assistant that can read a user's calendar but cannot create events on their behalf can advise but never act — a meaningful ceiling on utility.

The missing piece is a well-defined, consent-gated write channel: the agent sends a structured invocation message, the device validates the user's permission, executes the action, and replies with a structured result. The round-trip completes inside the existing XMTP conversation so the user sees what happened, and the full history is preserved.

## Goals

- [ ] Define a `DataSink` protocol that is the write counterpart to `DataSource`, with action schema discovery built in
- [ ] Implement `CalendarDataSink` supporting `create_event`, `update_event`, and `delete_event`
- [ ] Introduce two new XMTP content types (`ConnectionInvocation`, `ConnectionInvocationResult`) for the agent-to-device invocation round-trip
- [ ] Extend the enablement model to per-capability granularity (read, writeCreate, writeUpdate, writeDelete) per `(ConnectionKind, conversationId)`
- [ ] Expose an always-confirm toggle (default off) so users who want extra friction get it
- [ ] Produce an in-package invocation history so the host app can surface an audit log to the user
- [ ] Keep all changes additive; nothing here breaks the existing read path

## Non-Goals

- Write support for any source other than Calendar in v1 (Contacts, HealthKit share, Photos, HomeKit scenes, Screen Time restrictions are explicitly deferred)
- Batch or transactional multi-step actions (e.g., "move all Monday meetings to Tuesday")
- Rollback / undo of a completed write
- XMTP-level agent identity verification — that is handled at the messaging layer, not here
- Any UI inside `ConvosConnections` beyond updates to `ConnectionsDebugView`; settings UI, confirmation UI, and audit-log UI all live in the host app

## User Stories

### As a Convos user, I want to enable an agent to write to my calendar

I open connection settings for a conversation and see separate toggles for "Read calendar" and "Write calendar" (with sub-toggles for create, update, delete). I turn on write-create. From this point the agent can create events on my behalf. I can see a history of what it has created.

Acceptance criteria:
- [ ] Enablement UI (host app) shows independent toggles for each write capability
- [ ] Toggling write-create off immediately stops the agent from creating further events; existing events are unaffected
- [ ] History view shows every invocation with its timestamp, action, arguments, and result status

### As an AI agent, I want to create a calendar event for the user

The agent sends a `ConnectionInvocation` message with `actionName: "create_event"` and a structured args payload. The device receives the message, checks that write-create is enabled for this conversation, optionally shows a confirmation (if the user has the always-confirm toggle on), executes the `EKEventStore` write, and replies with a `ConnectionInvocationResult` carrying the new event's identifier.

Acceptance criteria:
- [ ] Agent can discover the supported actions and their input schemas before sending an invocation
- [ ] Device replies within the same conversation thread with a result or a structured error
- [ ] If always-confirm is on and the app is backgrounded, the device replies with a `requiresConfirmation` error rather than silently failing

### As a Convos user, I want confidence that agents cannot act without my explicit permission

Each write capability requires a separate opt-in. The always-confirm toggle adds a per-action modal even after opt-in. I can revoke any capability at any time.

Acceptance criteria:
- [ ] Write capabilities are disabled by default; a user must explicitly enable each one
- [ ] Revoking a capability causes subsequent invocations to return a `capabilityRevoked` error result
- [ ] The always-confirm toggle is surfaced per connection in the host app's settings

## Capability-Gated Enablement Model

The existing `Enablement` struct is keyed by `(ConnectionKind, conversationId)` and represents a single boolean. That flat model cannot represent "read yes, write-create yes, write-delete no" for the same `(kind, conversationId)` pair.

The replacement is a `ConnectionCapability` enum (`read`, `writeCreate`, `writeUpdate`, `writeDelete`) so that enablement becomes keyed by `(ConnectionKind, ConnectionCapability, conversationId)`. The `EnablementStore` protocol gains per-capability read and write methods alongside the existing ones; the existing `isEnabled(kind:conversationId:)` method maps to the `.read` capability for backward compatibility.

In the host app this is backed by GRDB with the inbox-scoped row model from PR 713. In the package's test and example targets it uses the existing `InMemoryEnablementStore`, extended with the new key shape.

The `ConnectionsManager` exposes capability-gated helpers that `CalendarDataSink` (and future sinks) call before executing any write.

## Consent UX

**Default posture:** The user explicitly opted in to the connection, the conversation, and the specific write capability. That three-layer consent is sufficient for most users. No per-action modal is required by default.

**Always-confirm toggle:** A per-connection `alwaysConfirmWrites` flag (persisted by the `EnablementStore`) wraps every write execution in a confirmation step before it proceeds. When enabled and the app is foregrounded, the host app presents the confirmation — the package exposes no SwiftUI for it. When enabled and the app is backgrounded, the device cannot present UI, so the invocation immediately returns a `requiresConfirmation` error result to the agent — the action is not attempted.

**Confirmation UI ownership:** Host app. The package exposes a `ConfirmationRequest` value and a callback-style API (`ConnectionsManager.setConfirmationHandler`) that the host implements to render its own sheet, system alert, or whatever fits Convos' chat UI. The package never imports `UIKit` or renders its own confirmation chrome.

The always-confirm flag is off by default. It is surfaced in the host app's connection detail settings, not inside the package itself.

## Security Posture

**Threats we address:**

- *Ordinary agent acting faster than the user expected* — per-capability opt-in and the always-confirm option give the user control over the velocity of writes.
- *Confused agent hallucinating unsupported actions* — every `DataSink` publishes a machine-readable action schema; the agent can (and should) discover supported actions before sending an invocation. Unknown `actionName` values return a structured `unknownAction` error.
- *Malicious agent in a group conversation* — write capabilities are enabled per conversation. A user who adds a malicious participant to a group should not also lose device write capabilities from that act alone; the agent must already be in a conversation where the user has granted write capability.

**Threats we deliberately do not address here:**

- XMTP-level impersonation (whether a sender is who they claim to be) — that is the responsibility of the XMTP identity and consent layer, not this package.
- Privilege escalation via replay of a captured `ConnectionInvocation` message — invocations carry a client-generated `invocationId`; deduplication is a host-app responsibility if desired, not enforced by the package.

**Residual risk of default-off confirm:** Most users will leave always-confirm off, meaning an agent with write-create capability can create calendar events without a per-action prompt. This is intentional — the friction budget was spent on the initial opt-in. Users who want higher friction opt in to always-confirm explicitly.

## Failure Modes and Result Semantics

Every invocation receives a `ConnectionInvocationResult`, whether it succeeds or fails. The result carries the original `invocationId` so the agent can correlate. Possible `status` values:

- `success` — write completed; `result` contains source-specific output (e.g., the new event's `EKEvent` identifier)
- `capabilityNotEnabled` — the user has not granted the required capability for this conversation
- `capabilityRevoked` — capability was revoked after the invocation arrived but before execution
- `requiresConfirmation` — always-confirm is on but the app is not foregrounded
- `authorizationDenied` — the underlying OS permission (e.g., Calendar access) has been revoked
- `executionFailed` — the `EKEventStore` call threw; the `error` field carries a human-readable description
- `unknownAction` — `actionName` is not recognized by this sink

The host app delivers the result message back through `ConnectionDelivering`, keeping the package transport-agnostic.

**Idempotency:** The package does not enforce write idempotency. If an agent sends the same `ConnectionInvocation` twice (e.g., after a network retry), two calendar events may be created. The `invocationId` is surfaced in the invocation history so the user can detect duplicates, but deduplication is out of scope for v1.

## Observability

Invocations and their results are ordinary XMTP messages carrying the two new content types. They persist wherever XMTP messages persist — on the XMTP network itself and in Convos' GRDB message store once PR 713 lands. The package does **not** duplicate that state: there is no persistent invocation history inside `ConvosConnections`.

For debugging and the example app, `ConnectionsManager` does maintain a bounded **in-memory** invocation log (`RecordedInvocation`) parallel to the existing `RecordedPayload` read log. Each entry captures the `invocationId`, `connectionKind`, `actionName`, arguments, result status, and timestamp. This is lost on relaunch — it exists to help engineers during development, not to be the system of record.

The host app's audit log UI pulls from the GRDB message table (filtered to the two new content types), not from the package. `ConnectionsConnectionsExample` ships a simple SwiftUI view over the in-memory log so contributors can see invocations flow through; the core package ships no UI.

## PR 713 Interaction

The `DataSink` protocol, `ConnectionCapability` enum, and the two new content type structs are purely additive to the existing package. They do not touch the read path. The package compiles and the existing tests pass without the main-app wiring.

The main-app adapter work — content-type codec registration, delivery of `ConnectionInvocationResult` messages back through XMTP, and the GRDB schema addition for per-capability enablement — depends on PR 713's single-inbox refactor because the GRDB schema and codec-registration path are both touched by that refactor. Those adapter pieces should be authored against PR 713 and land after it merges (checkpoint C6 or later). Package-only work can proceed on a separate branch today.

## v1 Success Criteria

- [ ] `DataSink` protocol is defined in the package with action schema discovery
- [ ] `CalendarDataSink` implements `create_event`, `update_event`, and `delete_event` against `EKEventStore`
- [ ] `ConnectionInvocation` and `ConnectionInvocationResult` types are defined and encodable
- [ ] `EnablementStore` supports per-capability granularity; existing read enablement behavior is unchanged
- [ ] Always-confirm flag is stored and respected; backgrounded invocations return `requiresConfirmation`
- [ ] `ConnectionsManager` routes incoming invocations to the correct `DataSink` and delivers results
- [ ] In-memory invocation history is accessible via `ConnectionsManager` and rendered in the example app's debug feed
- [ ] Unit tests cover: capability gating, always-confirm backgrounded case, each `CalendarDataSink` action, and each structured error result
- [ ] Package compiles on macOS (no `UIKit` or `EventKitUI` in the package layer)

## Calendar-Specific Decisions

These were the `CalendarDataSink` details that needed pinning before implementation:

- **Default calendar when unspecified.** Use `EKEventStore.defaultCalendarForNewEvents`. The agent may omit the `calendar` arg entirely and get the user's Calendar-app default. If the agent specifies a calendar by name and multiple calendars match (e.g., two "Work" calendars from different accounts), return `executionFailed` with an error explaining the collision; the agent should disambiguate by id.
- **Timezone handling.** Strict. The agent must include an explicit IANA timezone identifier with every event datetime (e.g., `"2026-05-01T15:00:00-07:00"` with a separate `timeZone: "America/Los_Angeles"` field, or an RFC 3339 offset that the sink resolves). Missing or ambiguous timezones return `executionFailed` rather than being silently interpreted — the cost of guessing wrong on scheduling is too high.
- **Recurring-event semantics.** `update_event` and `delete_event` on a recurring series default to `.futureEvents` (this instance and all subsequent). The agent may pass a `span` argument of `"thisEvent"` or `"futureEvents"` to override. We deliberately do not expose "all instances" in v1 — that blast radius deserves its own round-trip with explicit confirmation.

## Open Questions

None at draft-close. All open questions from the initial draft were resolved — see `Consent UX`, `Observability`, and `Calendar-Specific Decisions` sections above.

## References

- [ConvosConnections README](../../ConvosConnections/README.md)
- [Convos Extensions Architecture](./convos-extensions-architecture.md)
- [ConvosInvites Package](./convos-invites-swift-package.md)
