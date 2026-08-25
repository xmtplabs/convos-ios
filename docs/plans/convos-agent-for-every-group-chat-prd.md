# Product Strategy PRD: Convos — The Agent Layer for Every Group Chat

> **Status**: Draft for founder review
> **Authors**: Shane Mac and Quarter (strategy source); drafted by Codex
> **Created**: 2026-08-25
> **Updated**: 2026-08-25
> **Source**: “Quarter & Shane Convos Strategy after Board Meeting,” August 25, 2026
> **Prototype PR**: #1433 — SHANE MAC DO NOT MERGE

## 1. Executive Decision

Reposition Convos from **an AI group-chat app people must move into** to **the private agent layer that makes every group chat more useful, wherever that group already talks**.

The proposed category line is:

> **Any agent. Any group chat. One private place to work.**

The product promise is:

> Convos gives you an agent and lets you bring the agents you already use. Every agent can work privately beside any group chat, use only the context you choose, and share useful work back without taking over the conversation.

Convos should still be an excellent native group chat. It should stop requiring chat migration before people can experience its value. A group can receive meaningful value from Convos while continuing to live in iMessage, WhatsApp, Telegram, Slack, or another messenger. Migration becomes an earned outcome: people move a conversation into Convos only after the agent has become trusted and useful enough that the group wants the complete experience.

This changes the product’s center of gravity:

- From separate “group,” “personal,” and “external” agent concepts to one normalized **Agent** model.
- From the group transcript as the primary product to one private agent home and a consistent agent lane beside every Place.
- From “bring your own agent” as a separate power-user corner to **Add agent** in the same roster and picker as person-managed Convos Agents.
- From replacing existing messengers to adding value beside them.
- From implicit shared context to explicit, inspectable permissions for every place the agent can access.

## 2. Decision State

This PRD deliberately separates what the August 25 conversation settled from what it only suggested.

### Confirmed direction from the conversation

1. **One Agent model, not one Agent limit.** Convos gives every person one first-party Agent to start; they may create more Convos Agents, connect Codex, Grok, Town, Tasklet, or future Agents, and use Agents shared by Hosts in their Places. All join the same access-aware roster instead of becoming separate product areas.
2. **Creating value outside Convos matters as much as creating value inside Convos.** Existing group chats are a distribution surface, not merely competitors to replace.
3. **Convos should not demand migration.** The product earns the right to become the main chat by being useful first.
4. **Context is permissioned by place.** No context crosses between groups by default, even when one Agent can access several groups.
5. **The agent’s best role is beside the social conversation.** Private recall, planning, research, coordination, and artifact creation are core; speaking in the group is a mode, not the product’s identity.
6. **The existing prototype contains valuable ingredients.** Personal context, side-agent chat, connected agents, explicit message handoff, and shareable output should be reframed rather than discarded.
7. **The direction must be prototyped and tested.** The conversation did not claim that the correct interaction model is already proven.

### Product recommendations in this PRD

These are the recommended resolution of tensions in the conversation and require review:

1. A native Convos group starts in **Listen** mode after clear participant disclosure; an outside chat starts with **selected-message sharing** until the group explicitly connects broader access.
2. In the first release, the agent never posts unprompted into a social group. It responds only when mentioned or explicitly asked; proactive work stays in the private agent lane until a human shares it.
3. A Place may have one active public responder in the first release, while every person can privately switch among their available agents beside that Place. This limits social noise without inventing a different kind of “group agent.”
4. Agent-created or deliberately shared outputs may become Convos Pages. Convos must not rewrite or track every ordinary link shared by a person.
5. The existing Your Space shell becomes **Agent Home**. The conversation index remains one gesture away but is no longer mixed into the agent’s home as a seven-row chat list.

### Still unresolved

- Whether the starter Agent’s customer-facing name is “Convos Agent,” “My Agent,” a personal name, or another identity.
- Whether Listen should be the default in every native Convo or only in groups created with an agent.
- Whether and when a group may contain more than one shared agent presence.
- Which external-chat integrations can support transparent continuous access versus selected-message forwarding.
- What the free baseline includes and when agent work consumes credits.
- How another member may invoke a Host’s paid agent or connected capability without receiving access to the Host’s private context or credentials.

## 3. Problem Statement

The current product model creates avoidable complexity and weak compounding:

### The agent is fragmented

Every Convo currently behaves as if it has a special group-local class of agent. A person should still be able to create an Agent for one group, but that Agent should live in the person’s manageable roster and use the same permissions, private thread, and lifecycle as every other Agent. “Bring your own agent” currently adds a second model, and the starter Convos Agent risks creating a third. A person should not have to understand why one agent lives in Home, another lives in a group, and another lives in a provider directory.

### Value starts too late

Convos currently asks a whole group to adopt a new messenger before the agent can help. Most important groups will continue using established iMessage and WhatsApp threads even when members like Convos. Requiring migration makes the hardest behavior change a prerequisite for the first useful outcome.

### Social chat and agent work want different behavior

People do not want an agent noisily participating in every social conversation. They do want the agent to remember decisions, organize links and files, coordinate calendars, research options, and make things from the conversation. Treating group speech as the agent’s defining capability obscures the quieter value people want.

### Permissions are difficult to understand

The current model asks a group-scoped agent to reach outward into a person’s services. A normalized Agent connected to a permissioned Place is simpler: the person can grant that relationship a bounded capability while withholding credentials, unrelated context, and write authority.

### The home experience lacks one clear subject

Your Space currently mixes personal profile, context library, conversation shortcuts, attention summaries, agent connections, and creation tools. These are useful, but the user cannot answer a simple question: “Whose space is this, and what is it for?” The answer should be: **this is where I work with my agents, see what they know, control where they can help, and share what they make.**

## 4. Product Thesis

Convos creates a private intelligence layer around group conversation.

Every person receives one starter Convos Agent. They may create additional Convos Agents—much as people create group agents today—and connect agents such as Codex, Grok, Town, Tasklet, or future providers. They may also use Agents that another Host makes available in a shared Place. Every available Agent appears in one **Agents** roster and obeys one interaction contract. An Agent can work with one or multiple **Places**—native Convos or outside group chats—but every person–Agent and Agent–Place relationship has its own explicit permission boundary.

Calendars, documents, browsing, payments, and other accounts are **connections or capabilities**, not another type of agent and not a third top-level product category. They become available only to the Agent and Place scopes the person permits.

An agent can:

- listen with transparent consent;
- privately summarize, recall, organize, research, plan, schedule, edit, and make;
- respond in a group when explicitly invoked and allowed;
- produce useful artifacts that can be shared back to any chosen group;
- protect the person’s credentials and unrelated context while selectively exposing capabilities;
- work across several places privately only when the person explicitly selects those scopes.

The counterintuitive product bet is:

> Convos wins by making groups better before asking groups to move.

## 5. The Two-Noun Mental Model

The customer should need only two nouns.

### 1. Agents

The intelligences you can work with. Convos includes one by default; a person may create more Convos Agents or connect Codex, Grok, Town, Tasklet, or another provider. Every Agent has the same basic surface: identity, private conversation, status, permitted context, capabilities, results, and share-back.

Connected Agents are peers in the interface, not hidden tools beneath the Convos Agent. The Convos Agent may help route a task later, but the person can always choose and talk directly to any Agent.

### 2. Places

The conversations and context boundaries where an Agent may help. A Place can be a native Convo or a linked outside chat. Every Place has its own people, context, permissions, provenance, and removal controls.

Everything else describes a relationship or an output:

- **Access** is the permission a person has to use an Agent and the permission an Agent has to use a Place.
- **Context** is what a Place or person permits an Agent to use.
- **Connections** are capabilities such as calendar, files, browsing, or payments available to a permitted Agent.
- **Work** is what an Agent makes: plans, documents, links, maps, decisions, polls, schedules, and other useful artifacts.
- **Host** is the person who makes an Agent available to other people in a Place.

### Terms to retire from customer-facing language

- “Group agent” as a distinct class of agent
- “Agent instance”
- “Harness”
- “Member ID layer”
- “Conversation stitching”
- “Bring your own agent” as a separate product area
- “Power” as a catch-all for both agents and services

These may remain implementation terms, but the interface should primarily say **Agents**, **Places**, **Connections**, **Listen**, **Paused**, and **Share**.

## 6. Audience and Jobs

### The organizer

The person already doing invisible coordination for a trip, family, club, event, or friend group. They need the agent to remember details, reconcile options, create a plan, and reduce repeated work without forcing everyone into a new workflow.

### The participant

The person who wants the benefit without configuring an agent or changing apps. They should be able to receive a useful answer or artifact, understand why the agent is present, pause it, and optionally get their own agent later.

### The multi-agent user

The person who already uses Codex, Grok, Town, Tasklet, or another agent. They want those agents to appear beside the Convos Agents they own, apply selected group context privately, and share the result without exposing private accounts, prompts, or unrelated work.

### The Host

The person who brings an agent into a shared place and controls its funding and permissions. A Host is rewarded for helping people receive useful agent outcomes—not merely for creating groups or accumulating members.

## 7. Experience Architecture

### 7.1 Agent Home

Agent Home replaces “Your Space” as the conceptual home of the app. It is not an inbox, dashboard, generic personal profile, or special home for only the Convos Agent. It is the common private workspace for every Agent a person can use.

The first viewport answers six questions:

1. Which Agent am I working with?
2. What did I miss across my Places?
3. What should I do now?
4. What is ready to review or share?
5. What can the active Agent see for this task?
6. Which Agents can I use, and what can each one do here?

Recommended hierarchy:

1. **Active Agent** — one compact Agent picker. The starter Convos Agent is selected by default.
2. **Your briefing** — one prominent, conversational narrative that says what changed, what needs the person, and what useful next action is available.
3. **Suggested actions** — only the small number of decisions, connection/setup steps, or ready-to-share work referenced in the narrative. This is not a general activity feed.
4. **Command entry** — one obvious text/voice action: “Ask an agent to find, make, plan, or remember anything.”
5. **Recent work** — a small number of useful artifacts or outcomes, not recent messages.
6. **Places** — where Agents work, with active Agent, mode, and privacy state. The full list opens separately.
7. **Context** — what the active Agent knows or may use, including the private library inherited from Your Space.
8. **Agents** — the unified roster of every Agent the person can use, with access and permission state plus an **Add agent** action; this is not a separate promotional section for external providers.

The complete Convos list stays one gesture away in a dedicated Convos world. Agent Home does not lead with three, seven, or an unlimited number of recent chats.

Changing Agents must not move the person into a different product area. It changes the active private thread and available capabilities while preserving the selected Place and explicitly showing any scope difference.

#### Your briefing

The briefing restores the narrative quality of the original Your Space concept. It should feel like a trusted person has read everything the user permitted and distilled the morning into one sentence—not like unread counts, a notification center, or an AI-generated essay.

Example states:

- **Catch up:** “Morning, Shane. You have **2 decisions** waiting and **3 updates worth catching up on**.”
- **Ready to share:** “Your Nashville plan is ready. **Review it** or **share it with Nashville Boys**.”
- **Set up:** “You are caught up. **Connect your calendar** so an Agent can find a time for Toronto Coworking Days.”
- **Add an Agent:** “Codex could finish the site Quarter shared. **Connect Codex** to work on it privately.”
- **Quiet state:** “You are caught up. Ask an Agent to make, find, plan, or remember something.”

Highlighted phrases are tappable and open the exact filtered updates, pending decisions, Agent work, setup flow, or share composer they describe. The briefing may contain one primary sentence and, only when necessary, one supporting sentence.

The ranking order is:

1. a human waiting on the person or a decision blocking a Place;
2. completed Agent work ready to review or share;
3. an important update the person missed;
4. a failed permission, disconnected Agent, or setup step needed for an explicit task;
5. a contextual suggestion when nothing requires attention.

The briefing must name people, Places, or work when useful, preserve provenance behind every claim, and use only context the person has permission to access. It must not fabricate urgency, turn all unread messages into work, or promote a Connection without tying it to a clear user benefit.

### 7.2 Convos

Convos remains the complete native conversation world: fast, private group chat with invitations, profiles, disappearing messages, attachments, and group settings. The chat must be good enough to become the group’s primary home when the group chooses.

Entering a Convo opens the social conversation first. A private agent lane remains beside it and keeps its draft and scroll position. Its header uses the same Agent picker as Home. Group context and artifacts remain accessible without turning the Convo into a dashboard.

### 7.3 The private agent lane

The private lane is where a person asks any available Agent to work from the current Place. It should feel like a sidecar to the group, not a second group transcript. Switching from Convos Agent to Codex or Grok changes the private Agent thread, not the Place or the user’s mental model.

The lane must always make scope legible:

- “Using Nashville Boys”
- “Using Nashville Boys + My calendar”
- “Using 3 selected messages”
- “Not using context from your other Convos”

The user can add or remove scopes before sending. Results remain private until explicitly shared.

The same Agent picker must appear consistently in:

- Agent Home;
- the private lane beside a Convo;
- the DM/conversation list when filtering or switching Agent threads;
- **Send to agent** on a message or selection;
- the share sheet for sending context into Convos;
- the result composer before sharing work back to a Place.

Every picker row shows identity, provider, Host or owner, connection state, and access to the current Place: **Full Place**, **Selected only**, **Ask for access**, or **Unavailable**. An Agent another Host makes available is a first-class selectable Agent, not a footnote or a copy added to the person’s account.

### 7.4 Agents

Agents is the access list behind every picker. It answers one question:

> Which Agents can I use, where can I use them, and what is each one allowed to do?

The default list is **All Agents available to you**, regardless of ownership:

- Convos Agents the person owns or manages;
- external Agents the person connected;
- Agents a Host shares through a Place;
- Agents available through an organization or future membership.

Ownership is metadata and a permission level, not the information architecture. If the roster becomes long, optional filters may expose **All**, **Owned**, **Connected**, **Shared**, and the current Place. The default remains All, ranked by relevance to the current Place and recent use.

#### Picker behavior

The compact picker in a Place is ordered by usefulness, not ownership:

1. **Available here** — selectable now with the current Place scope.
2. **Available to you, not this Place** — usable privately only within its existing grant; current Place context stays excluded unless the person chooses **Share selected context** or receives expanded access.
3. **Add an agent** — create a Convos Agent or connect another provider.

Do not make people choose between “Yours” and “Others” before they can act. A shared Agent should feel as easy to select as an owned Agent while remaining unmistakably attributed.

A typical shared row reads:

> **Quarter’s Planner**
>
> Hosted by Quarter · Toronto Coworking
>
> Full convo context · Private replies · Quarter pays

The picker row stays scannable; an adjacent info affordance opens the complete permission receipt. Tapping the row switches the private thread. **Agents & permissions** replaces a vague **Manage** action.

Every row communicates:

- Agent identity, provider, and purpose;
- who owns or Hosts it;
- where the person may use it;
- what context it can currently read;
- whether results stay private, can be shared with approval, or can respond on mention;
- who pays and whether a limit applies;
- online, working, paused, permission-needed, disconnected, or unavailable state.

Selecting any Agent opens the same access detail shell:

- name, image, provider, owner, and purpose;
- private thread and recent work;
- **Your access** — where the person may invoke it, who granted access, expiration, and cost responsibility;
- **Its access** — Places and context it may read, Connections it may use, and actions it may take;
- available Connections, approval rules, and cost limits;
- profile visibility and Host impact;
- controls appropriate to the person’s role.

Role-appropriate controls are:

- **Owner/manager:** edit identity and purpose, change Place permissions, manage Connections and budget, transfer, remove from a Place, or delete.
- **Connector:** manage personally granted context and Connections, remove from a Place where authorized, or disconnect the external Agent.
- **Member with shared access:** use within the granted scope, inspect the complete permission receipt, revoke personal context, hide it from their picker, leave the source Place, or request expanded access. They cannot edit the Agent or its group-wide permissions.

The access detail must make two directions impossible to confuse: **what you can ask this Agent to do** and **what this Agent can see or do in return**.

Creating a group-specific Convos Agent remains valid. The difference is that the Agent belongs to and is managed by a person, appears for everyone who has access in Agents, and is assigned to the Place through an inspectable permission relationship. It is not a separate “group agent” species embedded inside that group.

### 7.5 Place settings

Every Place gets one clear permission screen:

- source and platform;
- people with access;
- active public responder, privately available Agents, and Host;
- mode: Paused, Listen, Mention, or experimental Participate;
- context the agent may read;
- connections and capabilities each Agent may invoke;
- what the agent may write or share;
- who pays and any spend limit;
- activity and provenance;
- pause, disconnect, remove, and delete controls.

Permissions should be written as human outcomes, not API scopes. For example: “May find open times on Shane’s calendar” is preferable to “Calendar read.”

### 7.6 Convos Anywhere

Convos Anywhere is the bridge to groups that stay in other messengers.

The capability ladder should grow only as trust and platform support allow:

1. **Share selected messages** to the agent.
2. **Share an ongoing topic or bounded window** with explicit review.
3. **Connect the chat** with persistent, visible listening and a deep link back to the original group.
4. **Allow mention responses** in the outside group.
5. **Allow a carefully bounded participation mode** only after validation.

The app must not present an external chat as if it is secretly mirrored or screen-recorded. If a linked transcript view exists, it must be an explicit group connection with visible provenance, pause state, retention, and a clear route back to the source app.

### 7.7 Artifacts and Convos Pages

The strongest distribution object is useful work, not a copied transcript.

An agent-created plan, document, map, poll, list, answer, or schedule may open as a Convos Page that:

- renders the useful object first;
- names the Place it came from when the viewer has permission;
- shows who may view or edit;
- allows the group to continue improving it with the agent;
- returns to the source conversation;
- offers a quiet path to get or connect an agent.

Convos should not automatically shorten, wrap, or track every ordinary link people share. That would make normal conversation feel surveilled. A Convos Page is created only for agent work or an explicit “Make this shareable” action.

### 7.8 Host identity

The Host badge remains useful under the new model. It means:

> This person brought an agent into a shared place and is helping other people use it.

The badge opens the Host explanation and impact view. The long-term metric is **Empowering N people**: unique people who received or used a meaningful outcome from an agent the Host provides.

Membership alone is not sufficient evidence of empowerment. Until outcome events exist, prototypes may show a clearly labeled reach proxy; production should not call every invited member “empowered.”

## 8. Agent Modes and Social Behavior

### Paused

The active shared Agent receives no new context from the Place and cannot respond. Everyone can see the paused state. Any member may request or trigger a pause; resuming persistent access requires the Host or an authorized admin. Private Agents remain selected-message only unless separately permitted.

### Listen

The agent receives permitted new context and can privately summarize, organize, and prepare work. It does not post unprompted into the group.

Recommended default:

- Native Convo created with an agent: Listen after clear disclosure to every member.
- Outside chat: selected messages only until persistent access is explicitly connected.

### Mention

Listen behavior plus the ability to answer in the group when explicitly mentioned or when a person shares a private result into the group.

### Participate — experimental

The agent may contribute without a direct mention under a bounded policy. This is not part of the initial product contract. It should be tested only after Listen and Mention prove useful and non-annoying.

## 9. Permission and Privacy Contract

| Action | Default | Required user understanding |
|---|---|---|
| Read a native Convo created with the agent | Listen after visible disclosure | The agent is present, what it retains, and how anyone pauses it |
| Read an outside chat | Selected messages only | Exactly what was shared and whether access persists |
| Use context from another Place | Off | The person explicitly selects both scopes for private work |
| Reveal one Place’s context to another Place | Off | A human stages and confirms the exact output or source material |
| Use a connected Agent or capability | Off for the group | Credential owner grants a bounded capability and cost limit |
| Use an Agent shared by a Host | Only inside the access grant | The person can see the Host, permitted Places, context scope, actions, payer, and expiration |
| Post in a group | Mention-only | The agent is visibly identified and the triggering request is attributable |
| Share a private result | Draft only | The person chooses the destination and reviews before send |
| Resume after a group pause | Restricted | Host/admin confirms the Place’s listening state |

Non-negotiable rules:

1. No context crosses between Places by default.
2. A person’s private agent transcript is never visible to group members.
3. A Host or Agent owner can see aggregate usage and cost needed to operate a shared Agent, but cannot read another person’s private prompts or results unless that person explicitly shares them.
4. Credentials, prompts, private tools, and unrelated agent activity are never exposed through social profiles or shared-agent access.
5. Every answer or artifact preserves source provenance the viewer is allowed to inspect.
6. Removing a Place, Agent, Connection, or person–Agent access grant takes effect everywhere and has a visible completion state.
7. The interface never calls continuous access “just listening” without naming retention, use, and pause behavior.

## 10. First-Run Experience

Every person receives a basic Convos Agent automatically. First run should not begin with a provider directory, model picker, context grid, or empty chat list.

### First screen

> **Any agent. Any group chat. One private place to work.**
>
> Bring me a conversation. I can remember the details, help privately, and make something useful for the group.

Primary actions:

- Start a Convo
- Share messages from another chat
- Connect an existing chat, when supported

The person can ask the starter Convos Agent immediately. Additional owned, connected, or Host-shared Agents are introduced through the same picker after the first useful outcome or when a task requires one; the picker’s final row is simply **Add agent**.

### Activation moment

A person is activated when they:

1. give the agent one Place or bounded message set;
2. receive one useful private result;
3. understand how to share it back or keep it private.

The product should then offer the next smallest expansion: keep listening, connect another Place, add an Agent, add a needed Connection, or invite someone to use the result.

## 11. Agents and Connections

Person-managed Convos Agents, Host-shared Agents, Codex, Grok, Town, Tasklet, and future providers are all **Agents**. Calendars, files, browsers, wallets, and future services are **Connections** that give an Agent a capability. Agents and Connections must not be mixed into one directory or described as equivalent objects.

Each Agent row answers:

- Who or what am I talking to?
- What is this Agent good at?
- Which Places can it use?
- Is this Agent private to me or available to a Place?
- Who owns it and who pays?
- What did it most recently make?
- How do I remove it from a Place, transfer it, delete it, or disconnect it?

Each Connection answers:

- What does this let my agent do?
- Which Agents and Places may use it?
- Is it read-only, write-enabled, or approval-required?
- Who owns it?
- Who pays for its use?
- What was the most recent use?
- How do I revoke it?

Agent names may appear on a social profile only by explicit opt-in. Social identity exposes affinity, not access: seeing that Shane uses Codex never grants access to Shane’s Codex, files, prompts, or results.

Future shared-agent or Connection delegation should expose a narrow outcome—“research this,” “find a time,” “book within this limit”—rather than the underlying account or tool.

## 12. Free Baseline, Credits, and Host Rewards

The business model should reinforce context, connection, and useful outcomes rather than punish them.

### Recommended free baseline

- one starter Convos Agent, with the option to create more;
- one or more Places within a bounded retention/usage allowance;
- selected-message handoff;
- private summaries, recall, and lightweight coordination;
- transparent Listen and Mention modes in native Convos;
- manual sharing of results.

The exact limits remain an open pricing decision.

### Credits

Credits fund more agent work, better models, connected Agents, automation, and higher-cost actions. The interface should explain what consumes credits before a Host exposes a paid Agent or capability to a group.

### Host rewards

Hosts should be encouraged to bring more useful context and capabilities safely. A future reward loop may grant credits when:

- a new person meaningfully uses an agent the Host provides;
- someone connects their own agent after discovering it through a Host’s profile or artifact;
- a hosted Place repeatedly produces useful outcomes without trust violations.

Rewards must not pay for raw message volume, passive surveillance, invitations, or agent chatter.

## 13. What Changes from PR #1341 / #1433

### Preserve

- Private agent side lane beside a group conversation
- Explicit **Send to agent** message handoff
- Editable staging before anything is shared into a Convo
- Rich local context previews and provenance
- Searchable addresses, phone numbers, email, links, files, photos, and notes
- Connected Codex, Town, Tasklet, and Grok prototypes
- Agent result saving and destination selection
- Social agent-provider opt-in
- Host badge and explanation
- One-tap access to the complete Convos list
- Existing native group-chat quality, privacy, invite, and disappearing-message work

### Reframe

| Current prototype | New product model |
|---|---|
| Your Space | Agent Home |
| Me & My Stuff | Context: what an Agent may use and what it has saved |
| Agents across your convos | Agents you can use: owned, connected, and Host-shared, with permission state shown per Agent |
| Bring personal agents to Convos | Add agent—the final row in every Agent picker |
| Group-local agent | A person-managed Convos Agent assigned to this Place |
| Group / Agent / Context tabs | Social conversation / private Agent thread / resulting work |
| Model picker per group agent | One Agent picker; provider-specific models stay inside that Agent’s settings |
| Host as group-agent owner | Host as the person providing useful agent access to others |
| Seven recent Convos on Home | Complete Convos world one gesture away; Agent Home shows outcomes and needs |

### Remove or defer

- A chat list as the primary Agent Home content
- Multiple agents talking visibly inside one group in the initial release; multiple private Agent lanes remain supported
- Unprompted agent participation
- Automatic mirroring of outside transcripts
- Automatic Convos short links for every URL
- Broad “use my agent” delegation without capability, context, cost, and revocation boundaries
- Phone number, email, and wallet as launch requirements; they remain a future identity direction

## 14. Functional Requirements

### FR1 — Unified Agent roster

- Every person receives one starter Convos Agent and may create additional Convos Agents, connect external Agents, or receive access to Agents through a Place or organization.
- All Agents use one roster and one picker component across Home, Convos, DMs, message handoff, and sharing.
- Every Agent has a stable identity, provider, Host or owner, connection state, private thread, capability summary, access source, cost state, and Place-permission state.
- Customer-facing UI does not create a different class of first-party Agent for every group.
- The roster defaults to every Agent the person can use. Ownership filters are secondary.
- Controls change by role: owners manage, connectors manage their connection, and members inspect or revoke their own access without receiving owner controls.

### FR2 — Place-scoped context

- Every context item belongs to a Place, the person’s private Context, or an explicit multi-Place private task.
- Retrieval and generation enforce the selected scopes.
- The user can inspect and change scope before sending a task.
- Agent access is evaluated per Place and displayed as Full Place, Selected only, Ask for access, or Unavailable.

### FR3 — Visible presence and mode

- Every group member can see whether the agent is Paused, Listening, Mention-only, or experimental Participate.
- The UI explains retention, speech behavior, Host, and pause/resume authority.

### FR4 — Private work before public speech

- The agent can privately create a result from permitted group context.
- Nothing is posted to a group without an attributable invocation or human confirmation.

### FR5 — Outside-chat value

- A person can send selected messages into the agent from the iOS share surface.
- Persistent outside-chat connections, when added, preserve source links, permissions, and visible state.

### FR6 — Agents and Connections

- A person can add, receive, scope, inspect, switch, hide, and remove Agent access through one consistent surface.
- A person can connect, scope, inspect, and revoke capabilities such as calendar, files, browsing, and payments separately from Agents.
- A group cannot silently use a private Agent or Connection.
- A shared Agent never implies access to its owner’s private Context, Connections, prompts, or unrelated Places.

### FR7 — Portable useful work

- Results can be saved privately, edited, and shared to a chosen Place.
- Supported results can open as permission-aware Convos Pages.

### FR8 — Host loop

- A profile may show that a person Hosts the current Place.
- Host impact is based on meaningful agent use, not raw group membership.

### FR9 — Provenance and trust

- Results identify the Place(s), messages, people, Agents, and Connections used when the viewer has access.
- Pauses, revocations, removals, and failed permission changes have explicit states.

### FR10 — Native Convos remain first-class

- The complete conversation list remains one gesture away.
- Existing notification, invite, QR, profile, attachment, disappearing-message, and group-settings behavior remains reachable.

### FR11 — One context handoff and share-back contract

- **Send to agent** always opens the same Agent picker, regardless of provider or source Place.
- The user can review the selected messages, files, or context scope before an Agent receives them.
- **Use anywhere** is a permanent Home action, not a provider-specific utility or a secondary More-menu item.
- Every Agent result, artifact, saved file, and link can be saved privately, edited where supported, and shared through the same destination flow.
- The destination flow offers the native system share sheet for any installed chat app as well as authorized Convos Places. Convos destinations stage a draft for review; external destinations receive the real file, URL, or text through the operating system. Neither path auto-sends.
- Provider limitations appear as capabilities or typed unavailable states, not as a different navigation model.

### FR12 — Actionable Home briefing

- Home synthesizes permitted activity across Places and Agents into one concise narrative.
- Every highlighted claim or count opens the exact supporting items with provenance.
- The briefing can recommend catch-up, decision, review, share, connect, set up, retry, or create actions.
- Ranking favors human commitments and ready work over generic engagement or unread volume.
- Empty, offline, stale, partially indexed, permission-limited, and all-caught-up states use honest typed language.

## 15. Unified Product and Technical Contract

This PRD does not approve a backend rewrite. It does require the prototype and eventual implementation to behave as one system instead of several provider-specific products.

### Common Agent contract

Every Agent integration should normalize to the same product-level contract:

- stable Agent identity and provider metadata;
- authenticated connection state;
- one or more private threads;
- declared capabilities and limitations;
- Place-scoped context grants;
- read, write, approval, and cost boundaries;
- structured working, waiting, failed, disconnected, and complete states;
- results with provenance, persistence, and share-back actions.

Provider-specific authentication, transport, models, and tool APIs sit behind adapters. They may change what an Agent can do; they must not change where the person goes to select it, talk to it, give it context, or share its work.

### Common person–Agent access grant

An Agent appears in a person’s roster because an explicit access grant exists. The grant records:

- role: owner/manager, connector, or member;
- source: created by the person, connected account, shared through a Place, or future organization membership;
- where the person may invoke the Agent;
- actions and Connections available to that person;
- who pays, any personal limit, and whether approval is required;
- start, expiration, revocation, and source-Place membership state;
- what usage metadata the Host may see without exposing private prompts or results.

Leaving the Place that granted access, a Host revocation, an expired grant, or an ownership transfer updates the roster immediately and explains what happened. A shared Agent is never copied into the person’s account.

### Common Agent–Place relationship

An Agent is not copied into a group. It receives a permission relationship to a Place. That relationship records:

- access level: none, selected items, bounded window/topic, or persistent;
- speech level: private only, Mention, or future Participate;
- allowed Connections and actions;
- owner, Host, payer, and spend limit;
- retention, provenance, pause, and revocation state.

The person–Agent grant determines whether the person can use an Agent. The Agent–Place relationship determines what that Agent can do with a Place. The picker shows the intersection of both. A single normalized roster, context-handoff pipeline, private-thread presentation, and result/share-back pipeline should serve every person-managed, connected, and Host-shared Agent.

### Technical validation gate

Before selecting an architecture, prove that one connected external Agent can:

1. appear in the same picker as the Convos Agent;
2. receive a selected group message through the same handoff;
3. work in a private thread with visible scope;
4. return a result with provenance;
5. share that result back through the same destination flow.

The same slice must then work for an Agent shared by another Host, with the member seeing fewer controls but the same private thread, context scope, result, and share-back surfaces.

If that vertical slice needs provider-specific screens or duplicate concepts, the contract is not yet simple enough.

## 16. States and Ranges

The design must handle:

- zero Places, one Place, and dozens of Places;
- one starter Agent, several owned Convos Agents, several external Agents, several Host-shared Agents, disconnected Agents, expired grants, and revoked access;
- zero Connections, one active Connection, many Connections, expired credentials, and approval-required actions;
- an empty private Context library, a typical personal library, and the existing bounded large-context index;
- no work needing attention, one important decision, and several conflicting requests;
- no briefing data, a single clear action, several competing updates, stale indexing, and an all-caught-up state;
- agent online, working, waiting for approval, paused, out of credits, disconnected, and removed;
- a Place with no persistent connection, selected-message access, Listen, Mention, and future Participate;
- a new participant who has no Convos account;
- a Host leaving, transferring responsibility, losing payment capacity, or revoking a shared Agent or Connection;
- access inherited from one Place, access inherited from several Places, and loss of the final Place that granted access;
- offline and partially synchronized devices;
- Dynamic Type, VoiceOver, reduced motion, and narrow screens without hiding permission state.

## 17. Success Metrics

### North star

**People receiving useful outcomes from agents in shared Places.**

This measures value delivered through the social graph, not messages sent by agents.

### Activation

- Time from install to first useful private result
- Percentage of new users who understand what the agent can see and where it can speak
- Percentage who share the first result or intentionally keep it private
- Percentage who open or complete a briefing action and judge it relevant

### Value and retention

- Weekly Places producing a saved, acted-on, or shared result
- Repeat private-agent use from the same Place
- Context recalled successfully without reopening the original transcript
- Tasks completed across scheduling, planning, research, and artifact creation

### Growth

- People benefiting from a hosted agent before installing Convos
- Beneficiaries who later activate their own agent
- Convos Pages that lead to continued collaborative use rather than one-time clicks

### Trust guardrails

- Agent pause, removal, and block rates
- Unprompted-post complaints
- Permission reversals immediately after grant
- Reports of wrong-Place context or unexplained provenance
- Briefing dismissals, irrelevant-action reports, and false-urgency reports
- Shared-Agent or Connection cost disputes

No growth metric may override a trust guardrail.

## 18. Validation Plan

### Prototype questions

Within 30 seconds, a new person should be able to answer:

1. Whose agent is this?
2. What can it currently see?
3. Can it speak in this group?
4. How do I pause it?
5. Does it know things from another group?
6. Who pays when it uses a connected Agent or capability?
7. Can I switch Agents without leaving this Place or learning a new interface?
8. Why did Home tell me this, and can I reach the supporting conversation or work?

### Dogfood scenarios

1. **Trip planning:** flights, addresses, availability, research, and a shareable plan across an existing friend chat.
2. **Family logistics:** quiet recall and calendar coordination with strict privacy and no unsolicited group speech.
3. **Club or community:** one Host provides a useful agent to many people, produces artifacts, and sees an honest impact metric.

### Experiments before architecture expansion

1. Test “Any agent. Any group chat. One private place to work.” against “Your agent for every group chat” and “AI group chat” for comprehension and desire.
2. Test Listen versus selected-message default in a native group with clear disclosure.
3. Test whether people prefer private prepared work over agent messages in the transcript.
4. Test the outside-chat loop with the iOS share surface before building continuous mirroring.
5. Test whether Host identity motivates useful sharing without encouraging spam or surveillance.

The prototype is successful when users experience value without first moving the group, can explain the permission boundary, and voluntarily ask to deepen the connection.

## 19. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Continuous access feels like surveillance | Critical | Start outside chats with selected messages; require visible consent, retention, provenance, and pause for persistent access |
| One Agent leaks context across groups | Critical | Place-scoped retrieval by default; explicit multi-Place task scopes; tests and audit trail for every disclosure |
| The product still feels like several agent systems | High | Enforce the two-noun model; one roster, picker, private lane, handoff, permission relationship, and share-back contract |
| Agents damage social conversation | High | No unprompted speech in the initial contract; Listen and Mention first; obvious pause state |
| Host pays for uncontrolled shared-Agent usage | High | Access grants, per-person or per-Place spend limits, approval-required capabilities, typed denial, aggregate usage visibility, and future rewards |
| Shared access exposes private prompts or context | Critical | Private threads remain requester-only; Hosts see bounded aggregate operations data; every context grant is explicit and revocable |
| External platforms prevent continuous integration | High | Make selected-message handoff and artifacts useful on their own; treat persistent linking as an enhancement |
| Agent Home becomes another crowded dashboard | High | Lead with one concise briefing and its few referenced actions; keep Places, context, Agent roster, and chat index progressively disclosed |
| The briefing becomes noisy or manipulative | High | Rank human commitments and ready work first; require provenance; prohibit fabricated urgency and untethered setup promotion |
| Convos neglects native chat quality | Medium | Preserve the Convos world as a first-class destination and migration target |
| The market is early for personal agents | High | Prove immediate group jobs with the starter Agent; additional Agents remain optional |
| Technical rearchitecture dictates the UX | High | Validate the mental model and behavior with prototypes before committing to transport changes |

## 20. Phased Product Sequence

### Phase 0 — Confirm the mental model

- Approve positioning, nouns, privacy contract, and initial mode behavior.
- Prototype Agent Home, the unified Agent picker, and Place settings using existing local data.
- Validate the eight comprehension questions and three dogfood scenarios.

### Phase 1 — One Agent model across native Convos

- Reframe each existing group-local agent as a person-managed Convos Agent connected to a Place.
- Make an owned Convos Agent, one external Agent, and one Host-shared Agent use the same Home, picker, private lane, context handoff, and share-back flow.
- Make Agent Home, Places, context, Connections, and private threads coherent.
- Keep agent speech Mention-only and Listen work private by default.

### Phase 2 — Explicit permissions and shared capabilities

- Ship Place-scoped context inspection and revocation.
- Add narrow read/write/approval/cost boundaries for Agents and Connections.
- Define Host responsibility, transfer, spend limits, and impact events.

### Phase 3 — Convos Anywhere

- Make selected-message handoff excellent.
- Add supported linked-chat connections with visible source, state, and pause.
- Return useful work to outside groups through native shares and Convos Pages.

### Phase 4 — Earned participation and network effects

- Test bounded Participate behavior.
- Add privacy-safe Host rewards based on useful outcomes.
- Explore phone, email, wallet, and broader agent distribution only after the core trust loop works.

## 21. Explicit Non-Goals

- Replacing iMessage, WhatsApp, Slack, or Telegram as a prerequisite for value
- Screen-recording or silently mirroring every chat a person is in
- Building a universal inbox of copied transcripts
- Letting an agent read every Place because it belongs to one person
- Making people negotiate with a friend’s agent instead of the friend
- Letting several agents chatter in a group by default
- Exposing a Host’s accounts or credentials to group members
- Optimizing for agent message volume, raw invitations, or passive listening time
- Promising a phone number, email, wallet, or cross-platform continuous connection in the first release
- Finalizing backend architecture before validating the product model

## 22. Open Decisions for Founder Review

1. Approve or revise the category line: **Any agent. Any group chat. One private place to work.**
2. Confirm that Agent Home—not the chat list—is the default product home.
3. Confirm the initial speech contract: Listen privately, respond on mention, never post unprompted.
4. Confirm the asymmetric outside-chat default: selected messages first, persistent access only after explicit connection.
5. Confirm one active public responder per Place in the first release, with any number of private Agent threads beside it.
6. Confirm **Agents** and **Places** as the two customer-facing nouns; keep Connections subordinate and retire Powers.
7. Confirm Agents as the access model: every Agent a person can use, with ownership and source as permission attributes rather than top-level sections.
8. Confirm the Home briefing as the hero: one narrative with tappable catch-up, decision, review, share, connect, and setup actions.
9. Confirm **Use anywhere** as a permanent Home primitive for every Agent result, artifact, file, and link.
10. Define the smallest free baseline worth promising.
11. Decide what event qualifies a person as “empowered” for Host identity and rewards.
12. Decide which continuous outside-chat ingestion path should follow the explicit iOS share/import prototype: phone-number bridge or one platform-specific connection.
13. Decide whether Convos Pages are part of the first validation prototype or the next loop.

## 23. Approval Request

Review this PRD for one decision:

> Should the next prototype prove one unified Agent layer for every group chat—with the Convos Agent and external Agents using the same product contract—rather than continue extending separate group, personal, and provider-specific agent experiences?

If approved, Phase 0 should produce a focused Agent Home, one universal Agent picker, Place permissions, and one outside-chat value loop before any broader implementation plan is accepted.

## 24. Source Receipt and Exclusions

This PRD uses the full August 25 Quarter/Shane transcript as strategy evidence and reconciles it against the current PRODUCT.md, DESIGN.md, PR #1341, and inherited PR #1433 prototype surface.

The source also contains board reaction, team-role discussion, emotional context, and possible internal communications. Those statements are not product requirements and are intentionally excluded from this document. No task owner, deadline, external message, staffing decision, or approved technical rearchitecture was inferred from them.
