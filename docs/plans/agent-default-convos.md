# Default agent in every convo

## What

Every new conversation comes with an agent already in it. The agent is a bare
instance (no pre-generated template); the user shapes it by chatting with it
instead of typing a brief into the "Make an agent" builder. The builder entry
points (builder bar, contacts-picker row, empty-state CTA) are removed, and the
compose picker gains an always-present bottom button - "New convo / Invite
friends later" - that skips the invite step and lands straight in the
conversation, where the agent greets.

## Why

The Agent Builder made agent creation a separate, up-front authoring task:
write a brief, wait for template generation, then get the agent. Making the
agent a default participant flips that - the conversation is the builder, and
the agent's persona emerges from the chat itself.

## How it works

### Provisioning (cache time)

`UnusedConversationCache` already pre-creates one hidden (`isUnused = true`)
group per session so "new convo" is instant. After a preparation fully
completes (published, invite tag + signed invite minted), the cache now invokes
an injected agent provisioner (`configureAgentProvisioner`, wired by
`SessionManager.wireDefaultAgentProvisioner`). The provisioner:

1. Skips if the conversation already has a second member.
2. Calls `POST /v2/agents/join` with no `templateId` (the backend's documented
   "bare agent" mode) and `options: { onboarding: "default-convo",
   skipGreeting: true }`, polls for the agent inbox, then `addMembers` - the
   same direct-add path the builder used (`SessionManager.addAgentToConversation`).

Provisioning is best-effort and fire-and-forget; the pooled row is consumable
throughout. A claim-time backstop in `prepareNewConversation()` re-ensures the
agent in case the cache-time join failed (offline, backend error).
`DefaultConversationAgentCoordinator` dedupes concurrent ensures by sharing one
task per conversation id.

### Greeting cue (`conversation_ready`)

The agent joins the hidden conversation silently (`skipGreeting: true`). When
the user actually enters the conversation, the client sends an invisible custom
content type - `convos.org/conversation_ready:1.0` (`ConversationReadyCodec`,
JSON body `{"version":1}`) - and the agent runtime responds with its
welcome/greeting. The signal:

- fires from `SessionManager.commitClaimedConversation` (the single choke point
  where a claimed warm-cache row becomes visible), after awaiting the shared
  provision task, latched once per conversation per process;
- fires from `NewConversationViewModel`'s `.ready` handler for cache-miss
  conversations the state machine created fresh
  (`ensureDefaultAgentConversationReady`), excluding joins, existing convos,
  template spawns, and deferred-visibility flows (those wait for their commit);
- is never rendered, persisted, pushed, or unread-marking on any client
  (ignored in `CaughtUpMessageRouting`, dropped in the NSE, `shouldPush`
  false).

### UI changes

- Compose picker (`ContactsPickerView`, `.compose` mode): bottom CTA is always
  visible. Empty selection reads "New convo" with subtitle "Invite friends
  later" and proceeds with zero members; with a selection it reads "Continue"
  as before. `ComposeFlowView.handleProceed` accepts the empty selection.
- `ConversationsViewModel.onStartConvo()` always opens the compose flow now
  (previously it skipped the picker when the user had no pickable contacts -
  the picker's invite actions and skip button are exactly what a contactless
  user needs).
- Removed: `AgentBuilderBar` (and all its MainTabView reveal/height plumbing),
  the "Make an agent" row in the compose picker / Contacts tab top-three / the
  in-convo invite sheet, and the empty-state "Make an agent" CTA (now "New
  convo", opening the compose flow).

### Kept for now (follow-ups)

- The in-conversation agent surfaces (`AgentsInfoView` explainer,
  `ConversationViewModel.presentAgentBuilder()` from the chat plus-menu /
  info sheet) still exist: conversations created before this change have no
  default agent, and this remains the only way to add one there. Deciding
  their fate is a follow-up.
- `Agent Builder/` module, `AgentTemplateRepository`, and the share-extension
  creation path are untouched (the share extension still builds agents from
  shared content).
- Suggested-agent templates are still pickable in the compose picker; a convo
  created with a template agent will contain both the default agent and the
  template instance. Whether that's desirable is an open product question.

## Server-side contract (convos-assistants / convos-backend)

Most of what this flow needs already exists in the assistant runtime:

- Bare joins are supported: the worker's `template` is optional and a
  synthesized default template (`status: "default"`) is minted before init.
  Provisioning is not credits-gated.
- `options.skipGreeting` is plumbed end to end (backend join options ->
  worker `JoinOptionsSchema` -> runtime `/convos/init`); the greeting is
  runtime-sent (`static-greeting.eta.md`), never herald-sent.
- `options.onboarding` is a strict two-value enum: "agent-builder" |
  "first-impression". The client sends "agent-builder" on the bare join,
  which arms the self-build kickoff on the user's first message (and the
  agent-first prototype pair - convos-ios#1200 / convos-assistants#2855,
  variant slug `pr-2855` - auto-arms it for every bare join, with richer
  self-build greeting/kickoff templates).

What does not exist yet: any handling of `conversation_ready`. Herald drops
all non-`xmtp.org` content types before the worker or runtime see them
(`isDisplayableMessage` in `@xmtp/convos-cli`), so a greeting-cue handler
needs four coordinated edits: a codec + type guard in `@xmtp/convos-cli`, a
branch in `herald-lite/src/agent-streamer/router.ts`, an event variant in
`herald-lite/src/webhooks/index.ts`, and a handler in the Hermes runtime's
herald webhook dispatch. The assistant worker itself needs no change (it
forwards webhook bodies verbatim).

Until that lands, the interim behavior with `skipGreeting: true` +
`onboarding: "agent-builder"` is: the agent joins silently and speaks for
the first time in response to the user's first message (the ready signal is
still sent, and becomes the greet-on-entry trigger once the runtime handles
it).

## Environment gating

Provisioning and the ready signal are disabled only for `.tests`. If dev-only
rollout is wanted first, gate `SessionManager.defaultAgentProvisioningEnabled`
the way `eagerAgentDmEnabled` does.
