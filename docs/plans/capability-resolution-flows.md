# Capability Resolution: End-to-End User Flows

Companion to `docs/plans/capability-resolution.md`. That doc explains the
*model* (subjects, providers, resolutions, federation). This doc shows what
actually happens, tap by tap, when an agent asks for something — for the
device path (Apple Health, Apple Calendar, …) and the cloud path (Composio:
Strava, Google Calendar, …).

Both paths share an opening (agent posts a `capability_request`, the picker
card surfaces) and a closing (we post a `capability_request_result` reply).
The middle differs in *where* the linking work happens and *who owns* the
"is this provider linked?" answer.

## Device flow

```mermaid
sequenceDiagram
    autonumber
    participant Agent
    participant DB as iOS DB / repo
    participant ConvoVM as ConversationViewModel
    participant Picker as Picker card
    participant User
    participant iOS as iOS framework<br/>(HealthKit / EventKit / …)

    Agent->>DB: capability_request<br/>(subject, capability, requestId)
    DB-->>ConvoVM: pendingRequestPublisher emits
    ConvoVM->>Picker: computeLayout → .connectAndApprove
    Picker->>User: "Assistant wants to read your health data"
    User->>Picker: tap Connect on Apple Health
    Picker->>ConvoVM: onCapabilityConnect(device.health)
    ConvoVM->>iOS: requestAuthorization()
    iOS->>User: system permission sheet
    User->>iOS: Allow
    iOS-->>ConvoVM: authorized
    ConvoVM->>ConvoVM: re-register provider (live linkedByUser)
    ConvoVM->>ConvoVM: auto-approve captured request
    ConvoVM->>DB: setResolution([device.health], …)
    ConvoVM->>Agent: capability_request_result<br/>(approved, providers=[device.health])
    ConvoVM->>Picker: dismiss + flash "Connection approved" toast
```

Key idea: the Connect tap *is* the user's approval — there's no second
"Approve" button on the `.connectAndApprove` variant. The approve fires
against the **captured** request (so a newer request arriving during the OS
prompt can't get auto-approved on the original's behalf), and the result is
posted whether or not the local resolver write succeeds.

## Cloud flow

```mermaid
sequenceDiagram
    autonumber
    participant Agent
    participant DB as iOS DB / repo
    participant ConvoVM as ConversationViewModel
    participant Picker as Picker card
    participant User
    participant Backend as Convos backend
    participant OAuth as Composio OAuth<br/>(web view)

    Agent->>DB: capability_request<br/>(subject, capability, requestId)
    DB-->>ConvoVM: pendingRequestPublisher emits
    ConvoVM->>Picker: computeLayout
    Picker->>User: "Assistant wants to read your fitness data"
    User->>Picker: tap Connect on Strava
    Picker->>ConvoVM: onCapabilityConnect(composio.strava)
    ConvoVM->>Backend: initiateCloudConnection(strava)
    Backend-->>ConvoVM: OAuth URL + connectionRequestId
    ConvoVM->>OAuth: present ASWebAuthenticationSession
    User->>OAuth: sign in / grant scope
    OAuth-->>ConvoVM: redirect callback
    ConvoVM->>Backend: completeCloudConnection(connectionRequestId)
    Backend-->>ConvoVM: CloudConnection (entity + connection ids)
    ConvoVM->>DB: persist DBCloudConnection<br/>+ syncCloudProviders → registry
    ConvoVM->>ConvoVM: auto-approve captured request
    ConvoVM->>DB: setResolution + DBCloudConnectionGrant
    ConvoVM->>Agent: ProfileUpdate.metadata.connections<br/>(per-conversation grant)
    ConvoVM->>Agent: capability_request_result<br/>(approved, providers=[composio.strava])
    ConvoVM->>Picker: dismiss + flash "Connection approved" toast
```

The cloud side has two extra hops the device side doesn't:

- **Backend round-trip** for OAuth initiation + completion, since Composio
  tokens live server-side.
- **Per-conversation grant** (`DBCloudConnectionGrant` + a `ProfileUpdate`
  metadata write) so the agent's runtime knows *this conversation* is
  authorized to invoke the connection. The device side has no analog —
  iOS-framework permissions are device-wide, not per-conversation.

The user can also link a cloud connection pre-emptively in app settings
(`Convos/App Settings/ConnectionsListView.swift`) before any agent asks; the
flow is the same minus the `capability_request` opener.

## Wire payload, request

```mermaid
flowchart LR
    A[Agent] -- capability_request/1.0 --> Device
    Device -- capability_request_result/1.0 --> A
```

Request:

```json
{
  "version": 1,
  "requestId": "req-…",
  "subject": "fitness",
  "capability": "read",
  "rationale": "To summarize your training week",
  "preferredProviders": ["composio.strava"]
}
```

Result (approve / federating subject / multi-provider):

```json
{
  "version": 1,
  "requestId": "req-…",
  "status": "approved",
  "subject": "fitness",
  "capability": "read",
  "providers": ["composio.strava", "device.health"]
}
```

Result (deny / cancel — same shape, different status, empty providers):

```json
{
  "version": 1,
  "requestId": "req-…",
  "status": "denied",
  "subject": "fitness",
  "capability": "read",
  "providers": []
}
```

Provider IDs: `device.<ConnectionKind.rawValue>` for iOS-framework providers,
`composio.<canonical_service_name>` for cloud providers. `providers` is sorted
ascending so the wire payload is deterministic.

## Convos-cli agent loop

```mermaid
sequenceDiagram
    participant Agent as convos agent serve
    participant CLI as send-capability-request
    participant Device as iOS Convos
    participant User

    Agent->>CLI: send-capability-request --subject … --request-id req-X
    CLI-->>Device: capability_request
    Device-->>User: picker card
    User->>Device: Approve / Deny / Connect
    Device->>Agent: stdout `message` event<br/>(contentType=capability_request_result)
    Agent->>Agent: filter by typeId, match requestId,<br/>branch on status
```

The `message` event the agent sees on stdout:

```json
{
  "event": "message",
  "id": "ae41…",
  "senderInboxId": "8b70…",
  "contentType": {
    "authorityId": "convos.org",
    "typeId": "capability_request_result",
    "versionMajor": 1,
    "versionMinor": 0
  },
  "content": "{\"version\":1,\"requestId\":\"req-X\",\"status\":\"approved\", … }",
  "sentAt": "2026-04-28T15:24:43.938Z"
}
```

Minimal bash skeleton:

```bash
convos agent serve --name "Coach" | while IFS= read -r event; do
  type=$(echo "$event" | jq -r '.event')
  case "$type" in
    ready)
      conv=$(echo "$event" | jq -r '.conversationId')
      convos conversation send-capability-request "$conv" \
        --subject fitness --capability read \
        --rationale "I'd like to summarize your week." \
        --request-id req-week-summary
      ;;
    message)
      tid=$(echo "$event" | jq -r '.contentType.typeId')
      [ "$tid" = "capability_request_result" ] || continue
      result=$(echo "$event" | jq -r '.content')
      [ "$(echo "$result" | jq -r '.requestId')" = "req-week-summary" ] || continue
      status=$(echo "$result" | jq -r '.status')
      providers=$(echo "$result" | jq -r '.providers | join(",")')
      if [ "$status" = "approved" ]; then
        # invoke the matching tool against $providers
        printf '%s\n' '{"type":"send","text":"On it — pulling your week now."}'
      else
        printf '%s\n' '{"type":"send","text":"No worries, skipping that."}'
      fi
      ;;
  esac
done
```

There's no polling — the agent just keeps reading from `convos agent serve`'s
stdout. Reconnects auto-catchup, so a transient disconnect during the OS
prompt won't drop the result.

## State ownership at a glance

| Concern | Source of truth |
|---------|-----------------|
| Which providers exist for which subject (this session) | `CapabilityProviderRegistry` (in-memory) |
| Whether a device permission is granted | iOS framework, queried live by `DeviceCapabilityProvider.linkedByUser` |
| Whether a cloud OAuth grant exists | `DBCloudConnection` (mirrored from Composio via backend) |
| Which provider the user picked for `(subject, conversation, capability)` | `DBCapabilityResolution` |
| Per-conversation cloud grant | `DBCloudConnectionGrant` + published `ProfileUpdate.metadata.connections` |
| Which `capability_request` is still unanswered | computed on the fly by `CapabilityRequestRepository` (no separate table) |
