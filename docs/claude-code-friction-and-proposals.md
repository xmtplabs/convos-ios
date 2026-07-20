# Convos × Claude Code — Friction Points & Simplification Proposals

Session output, 2026-07-18. Goal 3 (pain points) and Goal 4 (proposals with
quantifiable outcomes). Every number below is measured from the codebases
today, most of them by `generate_arch_map.py` / `generate_arch_map_ios.py` /
`build_arch_comparison.py` — which means every metric here can be re-measured
automatically after any change.

---

## Part 1 — Pain points (Goal 3)

### P1. God files exceed what an agent can hold, and they sit exactly where features land

| File | Size |
|---|---|
| iOS `ConversationViewModel.swift` | ~4,000 lines + 4 `+Extension` files |
| Android `ConversationViewModel.kt` | 3,314 lines |
| Android `ConversationScreen.kt` | 3,053 lines |
| Android `MessagingService.kt` | 2,526 lines |
| Android `StreamProcessor.kt` | 2,435 lines |

Most new features touch the conversation surface, so agents must load one or
more of these to do anything — burning context on 95% irrelevant code, raising
the odds of misplaced edits, and producing PR diffs that are hard to review.
The constructor arity tells the same story: Android ConversationViewModel has
16 injected collaborators; iOS resolves 39.

### P2. Cross-platform vocabulary divergence breaks "port this from iOS" prompts

Seven systematic renames measured between the repos: Assistant↔Agent,
Stuff↔Things, ConversationList↔Conversations, ContactsList↔Contacts,
ConversationMembers↔ConversationMembersList, AssistantInfo↔AgentsInfo,
AssistantProcessingPowerInfo↔AgentPowerInfo. An agent told "port the iOS
AgentFilesLinks feature" greps Android for "AgentFilesLinks", finds nothing,
and either stalls or creates a duplicate under the wrong name. Every entry is
a silent tax on the highest-value agent workflow this team has (iOS-first,
Android-port — the pattern your plans docs already document).

### P3. The storage stacks are philosophical opposites, so ports are re-designs

Same domain, opposite factoring (measured):

| Concern | Android | iOS |
|---|---|---|
| Writes | via 26 store interfaces × (SQLDelight + InMemory) = 83 files | 29 per-operation Writer protocols |
| db → domain | 7 hydrators | folded into repositories |
| Reads | 19 repository classes | 26 repositories |

"Add a persisted mutation" on Android touches ~5–6 files (store interface,
SQLDelight impl, InMemory impl, hydrator, repository, VM); on iOS ~2–3
(writer protocol + impl, repository). Neither is wrong — but an agent that
just implemented the iOS side gets no structural guidance for the Android
side, and vice versa. There is no written mapping between the two shapes;
until today it lived in people's heads.

### P4. Doc drift actively misdirects agents

Instances found *this session*: architecture.md §9 describes deleted
multi-inbox machinery (InboxLifecycleManager et al.); §15 maps 13 of 31
ViewModels; §16 bootstraps identities in a loop that no longer exists; §2
lists deleted classes; CLAUDE.md/architecture.md say "18 ViewModels" (31);
iOS `docs/README.md` ADR index stops at 010 with a renamed 005 (14 exist);
`single-inbox-refactor.md` still says **Status: Draft** for shipped code.
Agents (and this one, until checked) design against docs first — stale docs
produce confidently-wrong plans referencing deleted classes.

### P5. iOS dependency opacity: collaborators invisible at the seams

iOS VMs take `session: SessionManagerProtocol` and resolve real collaborators
at call sites (`session.messagesRepository(for:)`), including inside
`+Extension` files. Nothing in a type's signature reveals what it touches —
an agent must read the whole body (see P1 for why that's expensive). Android's
constructor injection makes the same information visible in ~10 lines.
(Counterpoint kept in mind: the factory style is idiomatic and reduces
plumbing; the fix is visibility, not necessarily refactoring.)

### P6. Verification asymmetry between platforms

Android: the KMP fence yields 103 commonTest files running on plain JVM —
fast, emulator-free, agent-friendly. iOS: tests need xcodebuild + simulator,
and heavyweight surfaces concentrate logic in the least-testable place (a
4k-line VM). Both repos share the QA corpus (`qa/`, synced per SYNC.md) for
end-to-end verification, but per-change unit verification is much cheaper on
Android than iOS. Side effects of a change are therefore easier to catch
pre-merge on Android; on iOS the QA suite carries more of that load.

### P7. Small structural debris that costs attention

`inboxGym` is an empty Gradle module still in settings.gradle.kts;
`ConvosViewModel` is an empty object squatting on the best name in the module;
`android/file-support.md` is an iOS architecture doc living in the Android
tree; `ViewModelExtensions.kt` is a growing god-factory (creates ~20 VMs);
repositories split across `storage/repository/` and feature packages with no
stated rule.

---

## Part 2 — Proposals (Goal 4)

Each proposal has a baseline measured today, a target, and an automated way
to re-measure — all three metrics come from the generators committed this
session, so progress is checkable in CI, not by vibes.

### Proposal 1 — Converge the cross-platform vocabulary to zero glossary entries

**What:** Rename one side of each of the 7 divergent names (recommend
converging on iOS names where iOS shipped first: Agent*, Things*, plural
list-VMs — decide per entry in a 30-minute team pass). Pure mechanical
renames; Android's are IDE-safe refactors. Going forward, feature names are
agreed at 1-pager time (add a "cross-platform name" line to the PRD/1-pager
templates).

**Why it wins:** every "port from iOS" agent prompt starts working literally;
grep/parity tooling stops needing an alias table; the comparison map's parity
matching becomes exact.

**Metric (automated):** `build_arch_comparison.py` GLOSSARY size.
Baseline **7** → target **0**, enforced by CI failing when a new divergent
name appears (comparison run finds an unmatched near-miss).
Effort: ~1 day. Risk: low (renames only).

### Proposal 2 — File-size and constructor-arity budgets, enforced by the generators; split the four god files to meet them

**What:** Adopt two budgets: no source file > 1,500 lines; no VM with > 12
collaborators. Split the four offenders to meet them — by feature delegate,
matching seams that already exist: Android ConversationViewModel →
Attachments / Thinking / Connections / AgentBuilder delegates; iOS
ConversationViewModel → promote its 4 `+Extension` files plus
Info/Edit/Members into the dedicated child VMs Android already has (this
*also* closes 8 rows of the parity table's "view-without-VM" bucket — two
birds). MessagingService and StreamProcessor split by content-type family.

**Why it wins:** agent context per task drops (load a 600-line delegate, not
a 4k-line file); diffs localize; the split iOS VMs become independently
testable, attacking P6 where it's worst.

**Metric (automated):** add `maxFileLines` + `maxVmDeps` to the generated
architecture-map.json summary; CI warns on regression. Baselines today:
**4 files > 2,400 lines; max VM arity 16 (A) / 39 (iOS)** → targets
**0 files > 1,500; max arity ≤ 12 both platforms**. Secondary human metric:
median PR "files-read-to-review" for conversation-surface PRs.
Effort: 1–2 weeks incremental (one delegate at a time, each a small PR).
Risk: medium — mitigated by Android's JVM test coverage and the QA corpus.

### Proposal 3 — Make generated docs the only inventory, gate them in CI, and delete the lies

**What:** (a) Land this session's generators + generated docs (done, needs
commit); regenerate in CI/pre-push and fail on diff — inventory drift becomes
impossible. (b) One cleanup PR per repo deleting or correcting the stale
narrative: Android — delete §9, fix §15/§16 to point at generated files,
correct the counts, flip single-inbox-refactor.md to Shipped, remove
`inboxGym`, delete `ConvosViewModel`; iOS — regenerate the ADR index from
`docs/adr/*` (trivial script), add 011–014. (c) Add a short
`docs/porting-map.md` to both repos writing down the P3 structural mapping
(store+hydrator+repo ↔ repo+writer) so ports follow a recipe — the one
hand-written doc this proposal adds, because it encodes intent no scan can
recover.

**Why it wins:** kills P4 permanently for inventories (the class of drift we
caught four instances of), and turns the docs from a liability into the
thing agents should read first.

**Metric (automated):** CI `git diff --exit-code` on regenerated docs — drift
count pinned at **0** forever; stale-fact instances found by audit: baseline
**7** (this session's list) → **0** after the cleanup PR.
Effort: ~1 day. Risk: near zero.

### Sequencing

Proposal 3 first (cheap, makes everything else measurable), Proposal 1 second
(unblocks agent ports immediately), Proposal 2 rolling (one delegate per
week). All three metrics live in the same generated JSON, so a single CI job
reports vocabulary divergence, max file size, max VM arity, and doc freshness
on every PR.
