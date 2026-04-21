# 1-Pager: DMs on a Single Inbox

> **Status**: Draft
> **Author**: jarod
> **Created**: 2026-04-21
> **Updated**: 2026-04-21
> **Supersedes**: [PR #398 — DM one-pager (`dm-from-group.md`)](https://github.com/xmtplabs/convos-ios/pull/398) (draft written against the per-conversation-inbox model)
> **Depends on**: [PR #713 — Single-inbox identity refactor](https://github.com/xmtplabs/convos-ios/pull/713) / [ADR 011](../adr/011-single-inbox-identity-model.md)

## 1. Tweet Headline

> "Tap a member in a group → start a private Convo with them. Only people you've met can reach you. No requests box, ever."

## 2. Show, Don't Tell

_TBD (mockup pending)._ Minimum shots needed before approval:

- 🎨 Figma: App Settings → **Customize** → new **DMs enabled/disabled** toggle row (sits alongside Reveal mode / Include info with invites / Read receipts)
- 🎨 Figma: per-group **Allow DMs** tri-state (Off / Everyone / Select members) in the per-conversation settings sheet
- 🎨 Figma: inline member-picker for "Select members" mode
- 🎨 Figma: member long-press → **Send DM** affordance
- 🎨 Figma: DM appearing in home list with origin context — list of current shared convos ("from Alice in Book Club, Chess Club"). Label tracks shared-memberships, not DM policy.

## 3. How It Works

### Policy hierarchy

Two scopes control who can DM you:

| Scope | States | Default | Where it lives | Visibility |
|---|---|---|---|---|
| **App-level** | `DMs enabled` / `DMs disabled` | Enabled | `CustomizeSettingsView` (App Settings → Customize) — a new row on `GlobalConvoDefaults.shared` | local to your devices |
| **Per-group** | `Off` / `Everyone` / `Select members` | inherits app-level at the moment you join/create the group | per-conversation settings sheet | see "wire signals" |

New members joining a group are **never** auto-added to your Select-members list. You have to add them explicitly.

### What crosses the wire vs. stays local

| Signal | Private / Public | Mechanism |
|---|---|---|
| Does user U allow DMs in group G? (a binary bit) | **Public** to group G | `allows_dms: true/false` on the member's `ProfileUpdate` metadata. Reuses the existing profile-message pipeline; old clients ignore unknown keys. |
| Receiver's Select-members allow-list for group G | **Private** to the receiver's devices | Self-addressed XMTP DM stream to your own inbox, one message per group holding the allowed-inboxId list. XMTP device-sync propagates to your other devices for free. |
| Consent state on a DM (`.allowed` / `.denied`) | **Private** to receiver's devices | `XMTPiOS.PrivatePreferences.setConsentState(entries:)` with `entryType: .conversation_id`. Streams via device-sync automatically. |
| **Global per-user block** (explicit Block action) | **Private** to receiver's devices | Same API with `entryType: .inbox_id` — stops **all** future DMs / invites / group joins from that peer, across every shared group, at the SDK layer before Convos ever surfaces anything. **New for this feature**: extend `XMTPClientProvider` to wrap `client.preferences` (Convos today only uses conversation-level consent). |

Note: **no origin-group metadata on the DM itself.** The sender's invocation context is not carried on the wire. Origin context in the receiver's UI is computed locally from the shared-groups set — see the decision function below.

### Receiver decision function

Convos **never renders `.unknown`**. Every incoming DM resolves to `.allowed` (surfaces) or silent `.denied` (invisible). No Requests bucket.

The decision is keyed on **peerInboxId**, not the MLS group ID — DM stitching (see section below) can deliver multiple stream events for the same logical peer, and re-running the policy per event must be idempotent.

```
on incoming DM event for peerInboxId = S:
  0. idempotence: if a Dm with peerInboxId S already has a locally-recorded
     consent decision, reuse it. Skip policy re-evaluation. (Handles stitched
     DMs: a new installation on S's side spawns a new MLS group that joins
     the existing Dm — it must not resurface a peer we previously denied.)
  1. inbox-level consent for S:
       .denied → silent .denied, stop  (explicit Block wins over everything)
  2. shared = groups where both S and me are currently members (local DB)
       ∅ → silent .denied  (can only DM people you've met in a Convo)
  3. for each g ∈ shared, evaluate policy(g, S):
       - off       → does not allow
       - everyone  → allows
       - select    → allows iff S ∈ localAllowList[g]
     allowedGroups = { g ∈ shared : policy(g, S) allows }
  4. allowedGroups = ∅ → silent .denied
     allowedGroups ≠ ∅ → .allowed, surface
  5. write consent state via xmtp.preferences.setConsentState (conversation-level)
  6. if .allowed, surface in home list. Origin label is computed live from
     the full (unfiltered) current shared-groups set, NOT allowedGroups:
         "from [S's display name] in [shared joined by commas, truncated]"
```

Key properties of this design:

- **"Any allowed path" wins at acceptance time.** If the user has said "anyone in Book Club can DM me" *and* "only these 3 people in Chess Club can DM me", a member of *either* group qualifies. Independent per-group consents, any of which is sufficient.
- **Consent and origin-context are decoupled.** The decision to accept a DM uses `allowedGroups` (shared groups the sender is permitted to DM from). The home-list origin label uses `shared` (all current shared groups, unfiltered). So if you accept a DM from Bob while Book Club allows DMs, then later turn Book Club DMs off, the *existing* DM stays visible with its "from Bob in Book Club" label intact — you're still in Book Club with Bob, that's the context. Future DMs from Bob would be denied (because `allowedGroups` is now empty), but past ones aren't retroactively reversed.
- **The label tracks memberships, not policy.** It re-renders only when `shared` changes — i.e., when either of you actually joins or leaves a group together. Flipping your DM policy doesn't touch it.
- **When both sides leave all shared groups** (`shared` becomes ∅), the label degrades to no context ("from Bob"). The DM itself remains `.allowed` — past decisions stand. To cut off the peer entirely, use explicit **Block** at the inboxId level.
- **Silent filtering** is the default on every branch that isn't `.allowed`. The sender never learns which branch fired.

### DM stitching considerations

XMTPiOS applies **DM stitching** ([docs](https://docs.xmtp.org/chat-apps/push-notifs/understand-push-notifs#understand-dm-stitching-and-push-notifications)): if the peer has multiple installations that each spawned their own MLS group before history-sync converged, a single logical Dm with that peer can have **N underlying MLS groups**. The SDK hides this at the message-read layer (fetch pulls messages from every stitched group, sends converge onto one), but the stream and push layers still emit per-MLS-group events.

Single-inbox doesn't eliminate stitching. ADR 011 says "one inbox per user" — but each **installation (device)** still registers separately, and cross-installation bootstraps (App Clip → main app, new phone signing in with iCloud Keychain) can create a second MLS group for the same peer pair before the history server has replayed the first one.

What this means for our design:

- **Receiver decision function is idempotent on `peerInboxId`** (step 0 above). A second welcome for the same peer reuses the prior decision without re-running policy.
- **`peerInboxId` stays stable.** Stitching changes the MLS-group cardinality; it doesn't mint new inboxIds. The `shared`-groups computation and the `allowedGroups` policy evaluation are unaffected — they already key on inboxId.
- **Consent semantics to verify (UAQ).** When we write `PrivatePreferences.setConsentState(entries: [.conversation_id(dmId, .denied)])`, does that consent record cover all MLS groups stitched into that Dm, or only the single group we resolved `dmId` from? If it's the latter, a new installation on the peer's side would create a new MLS group → new conversationId → our `.denied` wouldn't apply. **Mitigation**: inbox-level consent (`entryType: .inbox_id`) is immune to stitching by construction — blocking by inboxId denies the peer across every current and future MLS group. This strengthens the argument that the explicit **Block** action should always write both conversation-level *and* inbox-level consent.
- **Push notification subscription must enumerate all stitched topics.** From the XMTP docs: *"You will miss push notifications for messages if you are not listening to every potential topic."* When Convos registers push for a DM, it must subscribe to every MLS-group topic the stitched Dm currently owns, and re-subscribe when new groups are added.
- **NSE welcome filtering is required.** When a peer's new installation joins a stitched Dm, XMTP emits a welcome message. XMTP's push server *does not* filter these; if Convos' NSE treats every welcome as a new DM, users get spam notifications every time a peer gets a new phone. The NSE must recognize "this welcome is for a Dm I already have stitched" and drop the notification silently.

### Per-conversation profiles are display, not identity

Convos lets users present a different display name and avatar per conversation. That's **display pseudonymity** — changes how you appear in each convo's member list and message attribution — it is **not** cryptographic or protocol-level anonymity, and it is important the product communicates this clearly.

Concretely:

- Every user has exactly one `inboxId` (ADR 011). That's the real identity at the XMTP layer.
- MLS group members can enumerate each other's inboxIds. Anyone in two groups with you has the data to realize "this 'A' in Convo X and this 'B' in Convo Y are the same inboxId" — they just need to look. The Convos UI hides inboxIds from casual users, so casual observation doesn't make the link obvious, but the data is there.
- DMs address the `inboxId`, and XMTP stitches DMs to the same peer (see section above). So if you DM "A" from Convo X, then try to DM "B" from Convo Y, the second action resolves to the **same existing Dm** — exposing to you that A and B are the same person.

**Worked scenario.** J (inboxId `123`) is in Convo X with me-as-"A" and Convo Y with me-as-"B" (inboxId `321` in both). Convo Y is large and J has not realized A and B are the same person. J DMs "A" first — sees a DM with "A" in their home list. Later J clicks "Send DM" on "B": XMTP resolves to `inboxId 321`, returns the already-open Dm, and J's UI opens the "A" thread. J now knows A = B.

**This is a property of the chosen design, not a bug to patch.** The alternatives are:

- **Mint a fresh inbox per DM** — rejected when we chose single-inbox (ADR 011); would also break iCloud Keychain sync, NSE caching, and the explicit Block story.
- **Use separate 2-person Groups per origin context** — forfeits XMTP stitching (reintroducing the cross-installation fragmentation problem), breaks inbox-level consent as a coherent Block primitive (same inboxId → same block applies to both threads → still leaks), and complicates device-sync replay.

Both trades are strictly worse than the property we'd be trying to erase. And the property largely doesn't hide anything from the *receiver's* side either — a member of both origin groups already had the inboxId data needed to correlate.

**What per-conversation profiles actually deliver, and what they don't:**

| ✅ Do | ❌ Don't |
|---|---|
| Let you present differently (name, avatar, vibe) in each convo | Prevent other members of those convos from inferring you're the same account when they have enough context |
| Keep identity display local to each conversation's membership | Hide the underlying `inboxId`, which DMs and stitched-DMs resolve to |
| Give social-layer pseudonymity useful for casual separation | Provide cryptographic or protocol-level anonymity |

**Product responsibility: communicate this clearly in-product.** Likely surfaces:

- Per-conversation profile editor — helper copy explaining "this changes how you look here, not who you are across Convos."
- Onboarding moment introducing DMs — a single card that names the property.
- Settings / help article linkable from the Customize → DMs toggle and the profile editor.

Exact copy + placement is a UAQ below.

### Sender flow

```
1. In group G, long-press member M's avatar (or tap → profile sheet)
2. Check: does M's memberProfile in G carry allows_dms == true?
   → no → "Send DM" is not shown
3. Tap "Send DM":
   - xmtpClient.conversations.newDm(with: M.inboxId)
   - The new DM inherits the sender's profile from group G by default
     (so "Taylor from Book Club" shows up as Taylor)
4. DM opens. Sender types and sends.
```

The DM carries no origin metadata on the wire. The receiver independently decides whether it resolves to `.allowed` based on their local policy across *all* shared groups with the sender, not against the specific G the sender initiated from.

### App-level toggle mechanics

The app-level toggle is a single row in `CustomizeSettingsView` (App Settings → Customize). It sits alongside the existing "Reveal mode", "Include info with invites", and "Read receipts" rows, using the same `customizeToggleRow` pattern. The value is a new `Bool` property on `GlobalConvoDefaults.shared` — the same defaults container that already holds `autoRevealPhotos`, `includeInfoWithInvites`, `sendReadReceipts`, etc.

This setting **only controls the default for newly joined/created groups**. Existing groups retain whatever per-group setting they already have.

- **When you join or create a new group** (via invite, QR, App Clip hand-off, or new-convo flow): your first `ProfileUpdate` for that group carries `allows_dms = GlobalConvoDefaults.shared.<dmsEnabledDefault>`. If you later change the app-level toggle, it doesn't retroactively republish for existing groups.
- **To silence DMs everywhere right now**, the user must explicitly flip each group's per-conversation toggle to `Off` (or the client can offer a "Disable DMs in all my existing groups" one-shot action — a UX question, not a protocol one).
- **Per-group dropdown** (per-conversation settings sheet):
  - `off` → publishes `allows_dms = false`
  - `everyone` → publishes `allows_dms = true`
  - `select members` → publishes `allows_dms = true`, opens member-picker, updates private allow-list via self-addressed XMTP DM

The public bit is intentionally binary (on/off). Senders cannot distinguish `everyone` from `select members` from the public data — that's what preserves silent filtering.

## 4. Who Cares

- **Group member meets someone interesting** → tap their avatar → DM opens instantly. Same inbox, new display identity inherited from the group.
- **User gets unsolicited DM from outside their network** → it never appears. No notification, no home-list entry, no "Request" to tap through. The Convos promise holds: "only people from your Convos can reach you."
- **User is in a sketchy group** → flip that group's Allow DMs to `off` → no one from that group can reach you privately, but the group chat continues.
- **User wants private sidebars with specific friends** → flip to `select members` → pick them → only those people can DM, silently invisible to everyone else.
- **Abuser slides in via any shared group** → receiver's explicit **Block** action writes `.denied` at the `entryType: .inbox_id` level → all future DM/invite/join attempts from that peer are auto-denied in the SDK across every shared group, before Convos ever surfaces anything. Step 1 of the decision function short-circuits on this before any per-group policy evaluation.

## 5. What It Isn't

- **Not a Requests bucket.** `.unknown` is transient only — never rendered. Users see approved DMs or nothing.
- **Not a directory.** No way to DM someone you don't share a group with. The decision function's step 2 requires at least one shared group; a DM from an inboxId you don't share any group with is silently `.denied`.
- **Not a fresh-inbox-per-DM flow.** The single inbox is used. Per-conversation profiles provide **display pseudonymity** (different names/avatars per convo) — not cryptographic identity separation. See [Per-conversation profiles are display, not identity](#per-conversation-profiles-are-display-not-identity) for what this does and doesn't protect against.
- **Not a new content type on the wire.** Old design (#398) introduced `convos.org/convo_request`; this design uses XMTP's native DM primitive + existing `ProfileUpdate` codec only. Zero new codecs, zero new back-channel protocols, zero new conversation-metadata fields.
- **Not scoped to an origin group.** Earlier revisions of this plan included an `originGroupId` on `ConversationCustomMetadata` so the receiver could apply a specific group's policy; dropped because the receiver can compute the shared-groups set locally and apply "any allowed path wins", which is simpler and matches the user's intent when they toggle each group independently.
- **Not group spinoffs.** Deferred to a follow-up plan with its own scoping decisions.

## 6. FAQ + UAQ

### FAQ

1. **Q**: How is this different from PR #398's proposal?
   **A**: #398 invented a custom `convos.org/convo_request` content type, a back-channel DM between group-level inboxes, and a self-addressed message stream — all workarounds for "every user has N inboxes, there's no stable address to DM". Single-inbox dissolves those workarounds. The policy model (app-level + per-group off/everyone/select + private select-list) is preserved because it's a **product** property, not an architectural one.

2. **Q**: Does the sender's inboxId leak between conversations?
   **A**: Yes — the peer you DM learns your inboxId. That's unavoidable once you DM anyone (XMTP addresses conversations by inbox). Other members of the shared group(s) learn nothing. The DM itself carries no origin metadata, so no server-side observer can correlate it to a specific origin group.

3. **Q**: What if the receiver has DMs disabled in the group I'd initiate from?
   **A**: Their public `allows_dms` bit for that group is `false`, so the sender's client hides the "Send DM" button in that group. If the receiver has DMs enabled in some *other* shared group, the sender can initiate from there — the receiver's decision function checks all shared groups, not just the invocation context.

4. **Q**: What profile does my DM use?
   **A**: v1 default: inherit the profile from the group the sender long-pressed from (so "Taylor from Book Club" DMs show up as Taylor). The DM is a regular conversation after creation, so the user can edit its profile the same way they'd edit any other. Explicit profile-choice sheet at DM creation is deferred unless usability data demands it.

5. **Q**: Can I DM someone I previously blocked?
   **A**: No. Block writes `.denied` at `entryType: .inbox_id` — the inboxId-level consent gate fires before any "Send DM" button is rendered, and receiver-side step 1 short-circuits before any per-group policy is even evaluated.

6. **Q**: What if the sender and I share no groups?
   **A**: Silent `.denied`. The decision function requires a non-empty shared-groups set. A DM from an inboxId you share no groups with — whether from a Convos user who just left all your groups, or from a non-Convos XMTP client — never appears.

7. **Q**: What if I turn off DMs in the group I met this person through, after we're already DMing?
   **A**: Nothing changes for the existing DM — consent stays `.allowed`, label still reads "from Alice in Book Club" because you're still both in Book Club together. The policy change only affects *future* incoming DMs. Alice can't start a new DM with you anymore (her "Send DM" button is hidden, and if she forces it the receiver decision function returns `.denied`), but the existing relationship is preserved.

8. **Q**: What if we both leave every shared group?
   **A**: The DM stays `.allowed` (past decisions aren't reversed), and the origin label degrades to no context ("from Alice"). To actually cut off the peer, use explicit **Block** (inboxId-level consent) — that's the one lever that kills all current *and* future activity from them.

### UAQ (decisions needed before leaving Draft)

- [ ] **Home-list filter for transient `.unknown`**. Brief window between "DM streams in" and "decision function writes consent". Home-list query must exclude both `.unknown` and `.denied`, not just `.denied`, to prevent flicker.
- [ ] **Shared-groups recomputation cadence**. When memberships change (join/leave, admin removal), each visible DM's origin label needs to re-render using the new `shared` set. Either recompute live on home-list query, or observe membership events and invalidate. Performance question to revisit once we know home-list size.
- [ ] **Origin label truncation**. If sender is in 7 shared groups with me, does the label say "in Book Club, Chess Club, +5"? What order — most recent, alphabetical, pinned-first? Needs design.
- [ ] **Self-addressed DM stream format**. One message per group with the full allow-list? Append-only log with adds/removes? Tombstones on group-leave? Needs a small sub-design.
- [ ] **Abuse reporting surface**. If we silently-deny, the user has no feedback loop to report abusers whose DMs they never saw. Do we lean on group-admin moderation instead? (Removing a bad member from the shared group kills their ability to DM anyone in it.)
- [ ] **Legal / safety review**. Does silent filtering meet the team's harm-reduction bar? Confirm with current policy.
- [ ] **Consent-API scope under stitching**. Does `PrivatePreferences.setConsentState(entries: [.conversation_id(dmId, .denied)])` apply across all MLS groups stitched into that Dm, or only the one group `dmId` resolves to? If the latter, we must always pair it with an `entryType: .inbox_id` write on the explicit Block path so a peer's new installation can't resurface a denied DM. Needs SDK confirmation or a targeted test against XMTPiOS.
- [ ] **How to communicate "profiles are display, not identity"**. Where and how does the product surface this? Helper text in the profile editor? A one-time onboarding card the first time someone customizes a per-convo profile? A link from Customize → DMs enabled? Help article? Exact copy matters — "not cryptographic anonymity" is accurate but too nerdy. Needs a writing + design pass.

## 7. Counterintuitive Angle

> "We designed away the Requests box. The feature just… doesn't have one. Every DM is already approved, or it never happened."

#398 had a muted "Request" row, inline Accept/Block bars, and a silent-filtering path for select-mode senders. The new product decision collapses three UX states into two (`.allowed` / silent `.denied`), which simplifies both UI and reasoning. Users never have to triage; the policy they chose does it for them.

## 8. Call to Action

- [x] ✅ **Build** v1 as specified
- [ ] 🧪 **Test** internally before exposing DMs in TestFlight — safety-review the silent-deny path
- [ ] 🚫 Drop (unlikely — cost is small, product demand is real)
- [ ] 💬 **Debate** the six UAQ items above before leaving Draft

### v1 scope

- `allows_dms` field on `ProfileUpdate` / `MemberProfile` metadata (public bit, binary)
- `XMTPClientProvider` extension exposing `PrivatePreferences.setConsentState` / `inboxIdState` / `streamConsent` — used by both the receiver decision function (conversation-level) and the explicit Block action (inboxId-level)
- Self-addressed XMTP DM stream for per-group Select-members list
- Receiver decision function with local shared-groups computation, idempotent on `peerInboxId` (handles DM stitching)
- **Push notification registration**: enumerate all MLS-group topics of a stitched Dm; re-subscribe when new groups are added. (Update in `MessagingService+PushNotifications.swift` / `IOSPushNotificationRegistrar`.)
- **NSE welcome filtering**: `CachedPushNotificationHandler` drops welcomes for Dms that are already stitched into a locally-known Dm with the same `peerInboxId`, so new-phone-installs don't spam notifications.
- App-level default toggle as a new row in `CustomizeSettingsView` (App Settings → Customize), backed by a new `Bool` on `GlobalConvoDefaults.shared`
- Per-group tri-state control in the per-conversation settings sheet (off / everyone / select members)
- Long-press member → Send DM affordance
- Sender profile inheritance from the group the sender initiated from
- Explicit **Block** action on DM → writes `.denied` at both conversation and inboxId level

### Explicitly deferred to v2

- Group spinoffs (needs its own plan; we can revisit whether it needs on-wire origin metadata or can ride the same local-shared-groups computation pattern)
- Explicit profile-choice sheet at DM creation
- DM-level conversation settings UX polish (renaming, re-theming, pinning, etc., beyond what normal conversations already support)

### Next steps if approved

1. Close PR #398 as superseded; preserve the spinoff prose into a dedicated v2 follow-up plan.
2. `swift-architect` pass — concrete API for `XMTPClientProvider` consent extension, storage location for per-group policy + select-list, and receiver decision-function integration point (likely `StreamProcessor` or a new `IncomingDmGate` service).
3. Design mockups for the six UAQ items.
4. Stack implementation PRs on top of this plan per `CLAUDE.md`'s `gt submit` flow, starting with the consent-API extension (smallest, unblocks everything else).
