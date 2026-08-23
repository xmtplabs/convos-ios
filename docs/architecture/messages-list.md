# Messages List Architecture (UICollectionView)

A reference for the conversation transcript: the scrolling list of message
bubbles, date separators, system rows, invite cards, and typing/thinking
indicators inside a conversation. It covers data flow, the data source, the
custom layout engine, cell binding, self-sizing, scroll/keyboard behavior,
gestures, the context menu, reactions, and insertion/update animations.

Line numbers are anchors as of branch `saulmc/bridge-show-agent-dm`; they drift
by a few lines over time, so grep the named symbol if a line is off. Unless
noted, package paths are relative to `ConvosCore/Sources/ConvosComposer/`, and
core model paths to `ConvosCore/Sources/ConvosCore/`.

---

## 0. Orientation: where everything lives

The transcript is **not** a SwiftUI `List` or `ScrollView`. It is a UIKit
`UICollectionView` driven by a **hand-written `UICollectionViewLayout`**
(a fork/derivation of the open-source [ChatLayout] engine) and diffed with
[DifferenceKit]. It is bridged into SwiftUI through a
`UIViewControllerRepresentable`.

Counterintuitively, almost none of it lives in the app target. The directory a
newcomer greps first, `Convos/Conversation Detail/Messages/`, holds only the
thin SwiftUI wrapper (`MessagesView.swift`) plus a few drawers and navigators.
The real machinery is a self-contained UIKit chat stack in the local Swift
package **`ConvosComposer`**.

Three modules are involved:

| Module | Path | Contents |
| --- | --- | --- |
| App target | `Convos/Conversation Detail/…` | `MessagesView` wrapper, `ConversationViewModel` (the data feed) |
| `ConvosComposer` | `ConvosCore/Sources/ConvosComposer/…` | The collection view, custom layout, data source, cells, gestures, context menu |
| `ConvosCore` | `ConvosCore/Sources/ConvosCore/…` | The value-type models (`MessagesListItemType`, `MessagesGroup`, `AnyMessage`), repositories, the grouping processor |

Entry points, top to bottom:

- `Convos/Conversation Detail/Messages/MessagesView.swift:203` — SwiftUI
  `body`; instantiates `MessagesViewRepresentable` and hosts the composer and
  the context-menu overlay.
- `MessagesViewRepresentable.swift:6` — the `UIViewControllerRepresentable`
  bridge.
- `Messages View Controller/View Controller/MessagesViewController.swift:32` —
  `public final class MessagesViewController: UIViewController`, the orchestrator
  (~1800 lines).
- `Messages Collection Layout/MessagesCollectionLayout.swift:8` —
  `open class MessagesCollectionLayout: UICollectionViewLayout`.

### Full file index

Collection view / controller / data source (`ConvosComposer`):

- `MessagesViewRepresentable.swift` — SwiftUI↔UIKit bridge.
- `Messages View Controller/View Controller/MessagesViewController.swift` — the controller.
- `Messages View Controller/View Controller/MessagesCollectionView.swift` — the `UICollectionView` subclass.
- `Messages View Controller/View Controller/Data Source/MessagesCollectionDataSource.swift` — data-source protocol.
- `.../Data Source/MessagesCollectionViewDataSource.swift` — concrete data source.
- `.../Data Source/CellFactory.swift` — cell dequeue + `CellConfig` closure bundle.
- `.../Data Source/DefaultMessagesLayoutDelegate.swift` — sizing + animation deltas.
- `.../Cells/MessagesListItemTypeCell.swift`, `.../Cells/TypingIndicatorCollectionCell.swift` — the two cell classes.
- `Messages View Controller/Helpers/UICollectionView+DifferenceKit.swift` — the staged-changeset applier.
- `Messages View Controller/Helpers/SetActor.swift` — deferred/serialized update actor.
- `Messages View Controller/Helpers/ManualAnimator.swift` — `CADisplayLink`-driven scroll animator.
- `Messages View Controller/Constants.swift` — bubble geometry constants.

Custom layout engine (`ConvosComposer/Messages Collection Layout/`):

- `MessagesCollectionLayout.swift`, `MessagesLayoutStateController.swift`,
  `MessagesLayoutAttributes.swift`, `MessagesLayoutInvalidationContext.swift`,
  `MessagesLayoutPositionSnapshot.swift`, `MessagesLayoutDelegate.swift`,
  `MessagesLayoutSettings.swift`, and `Models/` (`ItemModel`, `SectionModel`,
  `LayoutModel`, `ItemSize`, `ItemPath`, `ItemKind`, `ChangeItem`).

Diffing conformances:

- `MessagesListView/MessagesListItemType.swift` — `MessagesListItemType: Differentiable`.
- `Messages View Controller/Message Models/MessagesCollectionSection.swift` — `DifferentiableSection`.
- `Messages View Controller/Message Models/MessageTypes.swift` — `AnyMessage`/`DateGroup`/`Invite`/`ConversationUpdate` conformances.

SwiftUI bubble content (`ConvosComposer/MessagesListView/`):

- `MessagesGroupView.swift`, `MessagesGroupItemView.swift`, and
  `Messages List Items/*` (`MessageBubble`, `ReplyReferenceView`,
  `ReactionIndicatorView`, `TypingIndicatorView`, etc.).

Core models (`ConvosCore/Sources/ConvosCore/Storage/Models/`):

- `MessagesListItemType.swift`, `MessagesGroup.swift`, `MessagesListProcessor.swift`.

Data feed:

- `Storage/Repositories/MessagesRepository.swift`,
  `Storage/Repositories/MessagesListRepository.swift`,
  `Convos/Conversation Detail/ConversationViewModel.swift`.

> **Contrast:** the *Conversations list* screen
> (`Convos/Conversations List/View Controller/`) is a different feature and
> *does* use Apple's `UICollectionViewDiffableDataSource`. The *messages*
> transcript documented here does not — it deliberately uses DifferenceKit +
> the custom layout instead.

---

## 1. End-to-end data flow

A single change in the database eventually becomes a `performBatchUpdates` on
the collection view. The whole path:

```
GRDB ValueObservation (SQL: db.composeMessages)
  -> Combine publisher, .throttle(0.3s, latest)              MessagesRepository
  -> MessagesListProcessor.process(...)  (grouping)          MessagesListRepository
  -> CurrentValueSubject<[MessagesListItemType]>             MessagesListRepository
  -> ConversationViewModel.messages   (@Observable)          ConversationViewModel
  -> MessagesView (SwiftUI re-render)                        app target
  -> MessagesViewRepresentable.updateUIViewController        bridge
  -> messagesViewController.state = .init(messages: ...)     controller
  -> state.didSet -> processUpdates -> performUpdate         controller
  -> StagedChangeset(source, target).flattenIfPossible()     DifferenceKit
  -> collectionView.reload(using: changeSet)                 UICollectionView+DifferenceKit
  -> performBatchUpdates: insert / delete / reconfigure      custom layout animates
```

Stage by stage:

- **GRDB → Combine.** `MessagesRepository.conversationMessagesResultPublisher`
  (`MessagesRepository.swift:362`) is a `CombineLatest` of the conversation id
  and the current fetch limit, each `.removeDuplicates()`, mapped through a
  `ValueObservation.tracking { db in db.composeMessages(...) }`, `.publisher(in:)`,
  `.switchToLatest()`. The primary rate limiter is
  `.throttle(for: .seconds(0.3), scheduler: .main, latest: true)`
  (`MessagesRepository.swift:435`).
- **Grouping.** `MessagesListRepository` (`MessagesListRepository.swift:156`
  `startObserving()`) maps each result through `MessagesListProcessor`, which
  turns raw `[AnyMessage]` into `[MessagesListItemType]` — grouping consecutive
  same-sender messages into `MessagesGroup`s, inserting date separators and
  system rows, attaching agent contact cards, applying the builder-summary
  cutoff, and filtering hidden bundle ids. The result is pushed into a
  `CurrentValueSubject<[MessagesListItemType], Never>`
  (`MessagesListRepository.swift:61`), exposed as `messagesListPublisher`
  (`:122`).
- **ViewModel.** `ConversationViewModel` holds the `@Observable`
  `var messages: [MessagesListItemType]` (`ConversationViewModel.swift:504`).
  `primeInitialMessages(...)` (`:1424`) synchronously paints an initial batch so
  the transcript is on screen at open, and `observe()` (`:1680`) subscribes to
  `messagesListPublisher` (`.dropFirst()` so the prime is not double-applied),
  assigning `self.messages` on the main queue.
- **SwiftUI → controller.** Because the VM is `@Observable`, assigning
  `messages` re-renders `MessagesView`, which re-invokes
  `MessagesViewRepresentable.updateUIViewController`
  (`MessagesViewRepresentable.swift:220`), whose final act is
  `messagesViewController.state = .init(conversation:messages:...)` (`:289`).
  Setting `state` is what triggers the diff.

The representable does **no** diffing. It hands the entire processed array into
`state`; DifferenceKit computes the actual delta downstream.

---

## 2. The item model and diffing identity

### `MessagesListItemType`

`public enum MessagesListItemType`
(`Storage/Models/MessagesListItemType.swift:45`) is the single element type of
the list. Cases: `.messages(MessagesGroup)`, `.date(DateGroup)`, `.update(...)`,
`.invite(Invite)`, `.conversationInfo(Conversation)`, `.agentOutOfCredits`,
`.agentJoinStatus`, `.agentPresentInfo`, `.connectionEvent`,
`.capabilityConnect`, `.agentBuilderSummary`, `.agentActivating`,
`.agentDmInfo`, `.typingIndicator(typers:)`.

Its stable string `id` (`:69`) is the identity used for diffing. Two design
notes worth knowing, both documented inline:

- `.invite` returns the constant `"invite"` (`:85`) — the transcript hosts at
  most one invite card (index 0), so its identity is the *slot*, not the
  payload. Keying on the payload made every invite change an animated
  delete+insert that cross-faded two cards and restarted the Scan camera; a
  constant id makes those in-place reconfigurations instead.
- `.typingIndicator` returns the constant `"typing-indicator"` (`:107`).

Other computed helpers used by the pipeline: `alignment` (`:172`, see §6),
`shouldAnimate` (`origin == .inserted`, `:168`), `cellReuseIdentifier` /
`allCellReuseIdentifiers` (`:183`/`:216`), and `lastMessageId` / the array
extension `lastMessageId` (`:235`/`:255`, used by the scroll-to-bottom decision).

### `MessagesGroup`

`MessagesGroup` (`Storage/Models/MessagesGroup.swift:3`) is a value type with a
stable `let id: String` but a hand-written `==` (`:147`) and `hash(into:)`
(`:174`) that compare the group's `rawMessages`, `readByMembers`,
`voiceMemoTranscripts`, `thinkingByMessageId`, reactions (via `AnyMessage`),
`agentContactCard`, and a dozen presentation flags. This is what makes an
edit / reaction / status change / read-receipt inside an existing group flip the
group's content-equality while keeping its identity — the basis for an in-place
reconfigure rather than a delete+insert (see §4).

`MessagesListProcessor` (`Storage/Models/MessagesListProcessor.swift`) also
**splits** long same-sender runs into display groups of a bounded size and marks
them `continuesPreviousGroup` / `isContinuedBelow`, so one giant cell never has
to build and measure dozens of bubbles at once. The view renders the split
seamlessly (hides the sender label, tightens the seam).

### DifferenceKit conformances

The heart of diffing is one extension
(`MessagesListView/MessagesListItemType.swift:10`):

```swift
extension MessagesListItemType: @retroactive Differentiable {
    public var differenceIdentifier: Int { id.hashValue }             // identity
    public func isContentEqual(to source: MessagesListItemType) -> Bool {
        self == source                                                // content
    }
}
```

So **identity = `id.hashValue`** and **content-equality = full `Equatable ==`**.
Same identity + different content → DifferenceKit emits an *update*; new/removed
identity → *insert*/*delete*. `AnyMessage`, `DateGroup`, `Invite`, and
`ConversationUpdate` have matching `@retroactive Differentiable` conformances in
`Message Models/MessageTypes.swift:9` (`AnyMessage.differenceIdentifier =
messageId.hashValue`, and its `==` includes reactions and status).

---

## 3. The SwiftUI ↔ UIKit bridge

`MessagesViewRepresentable` (`MessagesViewRepresentable.swift:6`) is an
unusually wide `UIViewControllerRepresentable` — roughly 50 stored properties
(`:7`–`:85`): the `messages` array, the `conversation`/`invite`/
`hasLoadedAllMessages` flags, ~30 `on…` action closures, sheet-host layout knobs
(`bottomBarHeight`, `hasBottomBar`, `topContentInset`, `clippedTopOverflow`,
`onContentHeightChanged`), and two imperative trigger closures.

**The Coordinator holds no diffing state** (`:87`):

```swift
public class Coordinator {
    var scrollToBottomFunction: ((Bool) -> Void)?
    var messageInputFocusFunction: (() -> Void)?
}
```

Its only job is to store two callbacks that forward *imperative* host actions
into the controller.

- `makeUIViewController` (`:206`) creates the controller, wires the coordinator's
  two functions to `scrollToBottomForSend` / `messageInputDidBecomeFocused`, and
  registers them with the host via `scrollToBottomTrigger { … }` /
  `messageInputFocusTrigger { … }`. This is how the host can imperatively scroll
  the transcript to the bottom (e.g. right before sending) or focus the input.
- `updateUIViewController` (`:220`) runs on every SwiftUI render. It re-pushes
  all closures and scalars onto the controller (most controller setters have a
  `didSet` that forwards into the data source or triggers a reconfigure), then
  finishes by assigning `messagesViewController.state = .init(...)` (`:289`).

Two subtleties:

- **Ordering matters.** `bottomBarHeight` is assigned *before* `state`
  (`:227`–`:229`) so its deferred inset update enqueues ahead of the initial
  load's scroll-to-bottom completion.
- **Context-menu gating** (`:277`–`:286`): while the custom context menu is
  presented, the controller's `view.isUserInteractionEnabled` is turned off and
  the collection view's `panGestureRecognizer` is bounced
  (disabled→enabled) to cancel an in-flight scroll; when the menu dismisses,
  `restoreBottomInsetAfterContextMenu()` runs.

---

## 4. The data source and update pipeline

### A manual data source, not a diffable one

`MessagesCollectionViewDataSource`
(`.../Data Source/MessagesCollectionViewDataSource.swift:9`) is a plain
`@MainActor NSObject` conforming to `UICollectionViewDataSource`. It is backed by
a stored array with a `didSet` that recomputes the layout delegate:

```swift
var sections: [MessagesCollectionSection] = [] {
    didSet {
        layoutDelegate = DefaultMessagesLayoutDelegate(
            sections: sections, oldSections: layoutDelegate.sections)
    }
}
```

(`:10`). Recomputing on every assignment lets deletion animations read the
pre-delete item from `oldSections` (see §7/§11). `numberOfSections`,
`numberOfItemsInSection`, and `cellForItemAt` read straight from `sections`
(`:80`+).

The abstraction the controller depends on is the protocol
`MessagesCollectionDataSource`
(`.../Data Source/MessagesCollectionDataSource.swift:7`), which refines both
`UICollectionViewDataSource` and `MessagesLayoutDelegate`. The controller holds
`private let dataSource: MessagesCollectionDataSource` and sets
`messagesLayout.delegate = dataSource`, so the concrete data source is *also*
the layout's sizing/animation delegate (forwarding to `DefaultMessagesLayoutDelegate`).

### One section, always

There is exactly one section. `processUpdates`
(`MessagesViewController.swift:1077`) assembles the cell array and wraps it:

```swift
let sections: [MessagesCollectionSection] = [
    .init(id: 0, title: "", cells: cells)
]
```

(`:1160`). `MessagesCollectionSection`
(`Message Models/MessagesCollectionSection.swift`) is a `DifferentiableSection`
whose `differenceIdentifier` is `id` and whose `isContentEqual` compares only
`id` — so section content always expresses as element-level diffs, never a
section reload.

Inside `processUpdates`, the cell array starts as the processed `messages`
verbatim, then:

- prepends a leading `.conversationInfo(conversation)` cell when
  `hasLoadedAllMessages` and the header mode allows (`:~1118`);
- injects `.agentOutOfCredits(...)` cells after the relevant agent's last group,
  driven by `agentPowerDepletedByInboxId` (`:~1148`);
- clears the `.loadingPreviousMessages` flag on any update (`:~1090`).

### Computing and applying the diff

`performUpdate` (`MessagesViewController.swift:1213`):

```swift
let changeSet = StagedChangeset(source: dataSource.sections, target: sections)
                    .flattenIfPossible()
guard !changeSet.isEmpty else { completion?(); return }
...
collectionView.reload(
    using: changeSet,
    interrupt: { !$0.sectionInserted.isEmpty },
    onInterruptedReload: { /* reloadData + restore bottom anchor */ },
    completion: { ... },
    setData: { data in self.dataSource.sections = data }
)
```

`animated` is decided in `state.didSet` as
`oldValue?.conversation.id == state.conversation.id` — switching conversations
is unanimated; updates within a conversation animate. When not animated, the
`reload` runs inside `UIView.performWithoutAnimation`.

The `reload(using:interrupt:onInterruptedReload:completion:setData:)` helper is
the vendored ChatLayout/DifferenceKit applier
(`Helpers/UICollectionView+DifferenceKit.swift:10`). Per staged `Changeset` it
opens a `performBatchUpdates`, calls `setData(changeset.data)` first (keeping the
data source in lock-step with each staged mutation), then applies section
deletes/inserts/reloads/moves and element deletes/inserts/moves.

The load-bearing detail — **content updates become `reconfigureItems`, not
`reloadItems`** (`:81`):

```swift
if !changeset.elementUpdated.isEmpty {
    let indexPaths = changeset.elementUpdated.map { IndexPath(item: $0.element, section: $0.section) }
    reconfigureItems(at: indexPaths)
    (collectionViewLayout as? MessagesCollectionLayout)?.reconfigureItems(at: indexPaths)
}
```

`reconfigureItems` keeps the existing cell (and its hosted SwiftUI view) and
re-runs `setup(item:config:)`, an in-place update rather than a teardown. The
custom layout's own `reconfigureItems` must be called too, because the layout
only re-measures cells it has been told about (see the pairing note in §8).

Two special paths:

- **`interrupt` on section inserts.** Section inserts happen only on the initial
  load. When the changeset contains one, the helper bails out of staged batch
  updates and calls `onInterruptedReload`, which in the controller does
  `reloadData()` then `messagesLayout.restoreContentOffset(...)` anchored to the
  last footer/bottom (`MessagesViewController.swift:~1236`). So the first paint
  is a hard reload pinned to the bottom, not an animated batch update.
- **Off-window.** If `window == nil` the helper skips animation entirely:
  `setData(last)` then `reloadData()`.

`flattenIfPossible()` (`Helpers/UICollectionView+DifferenceKit.swift:104`)
coalesces DifferenceKit's separate delete-stage and insert-stage into one
`Changeset` when it is safe to (pure element delete followed by pure element
insert, no section changes). DifferenceKit splits them to dodge
`UICollectionView` limitations; flattening lets the custom layout see both in
one batch so cross-animations are correct.

### Changes that carry no changeset

Some inputs change how a cell renders without changing any item's value, so the
controller reconfigures visible cells by hand — always pairing
`collectionView.reconfigureItems(at:)` **with** `messagesLayout.reconfigureItems(at:)`:

- `expandedMessageIds.didSet` → `reconfigureCells(forMessageIds:)`
  (`MessagesViewController.swift:596`) for long-body expand/collapse.
- `agentPowerDepletedByInboxId.didSet` → `reconfigureCells(forSenderInboxIds:)`
  then replays `self.state = state` (`:1054`).
- `applySpaceLinkHandling(...)` → `reconfigureAllMessageCells()` (`:1040`) when
  the conversation Space link arrives.

---

## 5. `SetActor`: serializing updates and interruptions

Overlapping `performBatchUpdates` on a self-sizing custom layout crash or
mis-animate. `SetActor` (`Helpers/SetActor.swift:4`) exists to serialize
collection mutations behind interface animations.

It is a set with reaction callbacks:
`final class SetActor<Option: SetAlgebra, ReactionType>` with
`var options: Option { didSet { optionsChanged(...) } }`. A `Reaction` has an
`Action` (`.onEmpty`, `.onChange`, `.onInsertion(opt)`, `.onRemoval(opt)`) and an
`ExecutionType` (`.once` / `.eternal`); `.once` reactions are removed after
firing.

The controller holds two (`MessagesViewController.swift:90`):

- `currentInterfaceActions: SetActor<Set<InterfaceActions>, ReactionTypes>` —
  in-flight UIKit activity: `.changingKeyboardFrame`, `.changingContentInsets`,
  `.changingFrameSize`, `.sendingMessage`, `.scrollingToTop`,
  `.scrollingToBottom`, `.updatingCollectionInIsolation`,
  `.determiningBottomBarHeight` (`:71`).
- `currentControllerActions: SetActor<Set<ControllerActions>, ReactionTypes>` —
  `.loadingInitialMessages`, `.loadingPreviousMessages`, `.updatingCollection`
  (`:82`).

The gate, in `processUpdates` (`:1170`):

```swift
guard currentInterfaceActions.options.isEmpty else {
    scheduleDelayedUpdate(for: sections, animated: animated, completion: completion)
    return
}
performUpdate(...)
```

If any interface action is in flight, the update is not applied. Instead
`scheduleDelayedUpdate` (`:1188`) registers a `.once`, `.onEmpty` reaction:

```swift
currentInterfaceActions.removeAllReactions(.delayedUpdate)          // keep only the latest
let reaction = Reaction(type: .delayedUpdate, action: .onEmpty, executionType: .once,
    actionBlock: { [weak self] in self?.processUpdates(...) })
currentInterfaceActions.add(reaction: reaction)
```

The moment the interface-actions set drains to empty, the pending update
replays. `removeAllReactions(.delayedUpdate)` first means only the latest pending
update survives — coalescing bursts behind animations. During the diff itself the
controller inserts `.updatingCollection` / `.updatingCollectionInIsolation` and
clears them in the completion.

If the user drags mid-update, `handleScrollViewDidScroll` calls
`interruptCurrentUpdateAnimation()` (`:1324`), which schedules a no-op
`performBatchUpdates` to settle the layout cleanly.

---

## 6. The custom layout engine

`MessagesCollectionLayout` (`Messages Collection Layout/MessagesCollectionLayout.swift:8`)
is a fully manual `UICollectionViewLayout` — not flow, not compositional. It
overrides the class hooks so UIKit uses the custom subclasses (`:66`):

```swift
open override class var layoutAttributesClass: AnyClass { MessagesLayoutAttributes.self }
open override class var invalidationContextClass: AnyClass { MessagesLayoutInvalidationContext.self }
```

### Why not flow / compositional

Neither stock layout can simultaneously do self-sizing with estimated heights,
bottom-anchoring (chat style), *and* scroll-position preservation when items
insert above the viewport. This engine keeps its own source-of-truth geometry
model and answers every `layoutAttributesForElements(in:)` query by walking it.
There is even an explicit comment (`:365`+) noting that it must return `nil` from
`layoutAttributesForElements(in:)` between
`invalidateLayout(invalidateDataSourceCounts:)` and
`prepare(forCollectionViewUpdates:)` — the same UIKit bug that
`UICollectionViewCompositionalLayout` sidesteps with a private API (`:383`).

### The dual-model state controller

`MessagesLayoutStateController`
(`MessagesLayoutStateController.swift:24`) is the geometry engine. It holds
**two complete layout models** so it can supply correct pre- and post-batch
attributes for animations (`:98`):

```swift
private var layoutBeforeUpdate: LayoutModel<Layout>
private var layoutAfterUpdate: LayoutModel<Layout>?
```

The layout's `state` field (`.beforeUpdate` / `.afterUpdate`) selects which one
each query reads. `commitUpdates()` promotes after→before when a batch completes.

The model tree, top down:

- **`LayoutModel`** (`Models/LayoutModel.swift`) holds
  `sections: ContiguousArray<SectionModel>` plus identifier→index caches.
  `assembleLayout()` is the top-level offset accumulator: it starts
  `offsetY = settings.additionalInsets.top`, assigns each section's `offsetY`,
  and advances by `section.height + interSectionSpacing`.
- **`SectionModel`** (`Models/SectionModel.swift`) holds an optional zero-height
  header/footer and `items: ContiguousArray<ItemModel>`. `assembleLayout()`
  walks items accumulating `offsetY`; `setAndAssemble(item:at:)` computes the
  height delta and shifts all lower items + the footer (parallelized with
  `DispatchQueue.concurrentPerform`).
- **`ItemModel`** (`Models/ItemModel.swift`) is a value type storing an estimated
  `preferredSize`, an optional `calculatedSize`, `offsetY`, `calculatedOnce`,
  `alignment`, and `interItemSpacing`. `size = calculatedSize ?? preferredSize`.

So a cell's absolute Y = `additionalInsets.top` + accumulated section offsets +
intra-section item offset. `collectionViewContentSize` reads the last section's
`locationHeight + additionalInsets.bottom` (with a `-0.0001` width fudge that
works around an internal UIKit rect-check bug).

### Attributes and caching

`MessagesLayoutAttributes`
(`MessagesLayoutAttributes.swift`) subclasses `UICollectionViewLayoutAttributes`
and adds `alignment`, `interItemSpacing`, `additionalInsets`, `viewSize`,
`layoutFrame`, etc., with a deep `copy(with:)` and an extended `isEqual`.

The controller keeps two caches: a fast-path `cachedAttributesState`
(last `(rect, [attributes])` block) and a persistent
`cachedAttributeObjects[state][kind][ItemPath]` of the actual attribute *objects*
— reusing and mutating the same instance rather than reallocating. Reusing the
identical object is what keeps insert/delete animation copies in sync (see §11).

Horizontal placement is applied in `itemFrame(for:kind:at:isFinal:)`
(`MessagesLayoutStateController.swift:314`) based on the item's alignment
(`MessagesListItemAlignment`, `Storage/Models/MessagesListItemType.swift:3`):
`.leading`, `.trailing`, `.center`, or `.fullWidth`. Per
`MessagesListItemType.alignment` (`:172`), invite / conversationInfo / builder /
activating cards are `.center`; **everything else, including `.messages`, is
`.fullWidth`.** That means message rows are full-width cells and **left/right
bubble placement is done inside SwiftUI**, not by the layout (see §8).

### Invalidation

`MessagesLayoutInvalidationContext`
(`MessagesLayoutInvalidationContext.swift`) adds one flag,
`invalidateLayoutMetrics` (default `true`); when `false` the layout skips the
expensive full resize/reassemble — used for pure content-offset/bounds changes
(a scroll should not re-measure everything).

`invalidateLayout(with:)` (`MessagesCollectionLayout.swift:633`) translates
context flags into a `PrepareActions` OptionSet (`:102`):
`.recreateSectionModels`, `.updateLayoutMetrics`, `.cachePreviousWidth`,
`.cachePreviousContentInsets`, `.switchStates`. `prepare()` (`:260`) then acts on
them — recreating the section tree from the data source, or (metrics-only)
resetting each item's size and re-assembling sections concurrently.

Visible-range search is not a linear scan: `allAttributes(at:visibleRect:)`
(`MessagesLayoutStateController.swift:981`) uses a binary search
(`RandomAccessCollection+Extension.swift`) to find the first visible item per
section, then walks forward until items leave the viewport. On animated batch
updates it can further restrict to items visible before *or* after the update
when `processOnlyVisibleItemsOnAnimatedBatchUpdates` is set.

---

## 7. Self-sizing, estimated heights, and bottom-anchoring

### Estimated vs. exact sizes

Sizes originate from the delegate's `sizeForItem` returning an `ItemSize`
(`Models/ItemSize.swift`): `.auto`, `.estimated(CGSize)`, or `.exact(CGSize)`.
`ItemModel` stores both the estimated `preferredSize` and an optional
`calculatedSize` (the measured value), returning `calculatedSize ?? preferredSize`.

`DefaultMessagesLayoutDelegate`
(`.../Data Source/DefaultMessagesLayoutDelegate.swift:23`) returns `.estimated`
for cells and `.exact(.zero)` for the (always-present, invisible) header/footer.
Estimates are hand-tuned per kind (invite 348, conversationInfo 300, date/update
48, agentBuilderSummary 320, agentDmInfo 260, typing 48, etc.), and message
groups get a detailed estimate from `estimatedHeight(for:width:)` (`:69`), which
sums per-message estimates from `messageHeight` (`:182`) — text scaled by
~35 chars/line × 21pt, attachments by aspect ratio, reply headers, reactions,
transcript rows, and the sent-status row. Accuracy matters: the comment (`:74`)
warns that a card-only group that self-sizes ~10× larger than its estimate can't
be absorbed by the bottom anchor during the open transition, so the estimate must
be close.

### Self-sizing report-back

Cells report their measured size via `preferredLayoutAttributesFitting`
(overridden to `layoutAttributesForHorizontalFittingRequired` — height measured,
width fixed). UIKit then calls:

- `shouldInvalidateLayout(forPreferredLayoutAttributes:withOriginalAttributes:)`
  (`MessagesCollectionLayout.swift:453`). The predicate (`:479`) invalidates when
  the item has never been calculated, or the measured height differs (rounded)
  **and the item is not exactly sized**, or alignment/spacing changed. The
  exact-sized exclusion (`isExactlySized`, `:1062`) is a Convos-specific fix for
  an infinite recursive-layout loop when an empty-state cell hosts taller than
  the delegate's fixed height.
- `invalidationContext(forPreferredLayoutAttributes:...)` (`:488`) writes the
  measured size back into the model via `controller.update(preferredSize:...)`,
  computes the height difference, and keeps pending-animation attributes in sync
  so an insert/delete animation doesn't start from the stale estimate.

### Bottom-anchoring (chat style)

The list is **not inverted and not transformed**. The model tree is top-down
(oldest at top); "stick to bottom" is achieved with explicit content-offset
compensation, gated by the protocol flag `keepContentOffsetAtBottomOnBatchUpdates`
(read throughout `MessagesLayoutStateController.swift`, e.g. `:519`, `:659`,
`:885`).

- **In-band growth.** When a visible item grows/shrinks during self-sizing,
  `invalidationContext(forPreferredLayoutAttributes:...)` adds the delta to
  `context.contentOffsetAdjustment.y` (`MessagesCollectionLayout.swift:569`) so
  the scroll offset moves in lockstep and the visible content stays put.
- **Out-of-band bottom growth.** For a large one-shot growth of the *last* item
  outside a batch update (media finishing async load, a sent message appending),
  compensating in one frame would snap the whole list. The layout detects this
  (`:557`, threshold `Constant.outOfBandGrowthRevealThreshold = 12.0`) and instead
  fires `onOutOfBandBottomGrowth`, letting the controller reveal the growth with
  an animated scroll. `compensatesAllSelfSizingGrowth` stays `true` until
  `viewDidAppear` to avoid a conversation-open flicker.
- **Batch updates.** `targetContentOffsetForProposedContentOffset` (`:710`)
  overrides the proposed offset when `controller.proposedCompensatingOffset != 0`;
  `finalizeCollectionViewUpdates()` (`:775`) applies any leftover
  `batchUpdateCompensatingOffset` via a fresh invalidation context.

### Position snapshots (pagination)

`MessagesLayoutPositionSnapshot`
(`MessagesLayoutPositionSnapshot.swift`) captures `{indexPath, kind, edge, offset}`.
`getContentOffsetSnapshot(from:)` / `restoreContentOffset(with:)`
(`MessagesCollectionLayout.swift:193`/`:233`) record and restore the position of a
reference item, so when older messages load *above* the viewport the visible
content stays logically stationary. During batch updates the controller also
records an `ItemToRestore` (last visible item + its offset from the visible
bottom) and adjusts its index as inserts/deletes shift it, computing a
`proposedCompensatingOffset` so the anchor item ends at the same screen position.

### Quiescent layout passes

`MessagesCollectionView.layoutSubviews`
(`.../View Controller/MessagesCollectionView.swift:23`) wraps
`super.layoutSubviews()` in `performWithoutAnimation` **unless** the layout is
mid-batch-update or inside an explicit `UIView` animation. This prevents a
SwiftUI-render-triggered self-sizing invalidation from inheriting an in-flight CA
transaction, which would make content dip by half the height delta for a few
frames. The view also exposes `onDidLayoutSubviews`, which the controller uses to
report content-height changes back to the host (`onContentHeightChanged`).

---

## 8. Cells and SwiftUI hosting

### Two registered cell classes

Only two cell classes are registered
(`MessagesCollectionViewDataSource.registerCells`, `:65`):
`MessagesListItemTypeCell` and `TypingIndicatorCollectionCell`.
`CellFactory.createCell` (`.../Data Source/CellFactory.swift:104`) branches on
the item: `.typingIndicator` → `TypingIndicatorCollectionCell`; **every other
case** → the single `MessagesListItemTypeCell` via `cell.setup(item:config:)`.
(The enum's per-case `cellReuseIdentifier` values exist but the composer only
ever dequeues these two.)

`CellConfig` (`CellFactory.swift:7`) is the immutable bundle of everything a cell
needs — the item id, resolvers, and all `on…` closures — rebuilt fresh per
`cellForItemAt` in the data source with `[weak self]` trampolines back to the
data source's handlers.

### Cells host SwiftUI via `UIHostingConfiguration`

`MessagesListItemTypeCell.setup(item:config:)`
(`.../Cells/MessagesListItemTypeCell.swift:63`) assigns
`contentConfiguration = UIHostingConfiguration { … }` with a `switch` over the
item case to the SwiftUI view — `MessagesGroupView` for `.messages`, `InviteView`,
`ConversationInfoPreview`, `AgentLostPowerStatus`, and so on. The root gets
`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rootAlignment)`, an
`.id("message-cell-\(item.differenceIdentifier)")` (`:173`) that resets per-cell
SwiftUI state across reuse, and injected `.environment` values (context menu,
resolvers, link router, Space URL).

Note this is `UIHostingConfiguration`, **not** `UIHostingController` — the cell
carries no child view controller.

Because message cells are full-width, **the bubble's left/right placement lives
in SwiftUI**: `MessagesGroupView` branches on `sender.isCurrentUser` to add
avatar-width leading padding for others and `HStack` + `Spacer()` right-alignment
for the current user.

The hosting root uses top alignment (`rootAlignment` = `.top` for centered items,
`.topLeading` otherwise, `:73`) rather than centering, so in-cell growth
animations don't produce a half-delta vertical jump (comment at `:64`).

### No `prepareForReuse` clearing — deliberate

There is intentionally **no** `prepareForReuse` that clears the configuration
(comment at `MessagesListItemTypeCell.swift:45`). `setup(item:)` runs on every
dequeue and assigns a fresh `UIHostingConfiguration` of the same generic type,
which UIKit applies as an *in-place update* of the existing hosting controller
rather than a teardown-and-rebuild. Per-item SwiftUI state still resets via the
content's `.id(...)`. Clearing the configuration on reuse measurably cost scroll
time. `TypingIndicatorCollectionCell.prepare(with:)` follows the same pattern,
hosting `TypingIndicatorView` keyed on the joined typer inbox ids.

`preferredLayoutAttributesFitting` (`:185`) calls
`layoutAttributesForHorizontalFittingRequired` so self-sizing measures height for
a fixed width (see §7).

---

## 9. Scroll behavior, pagination, and keyboard

### Scroll-to-bottom decision matrix

The decision runs in the `state.didSet` completion, after the diff applies
(`MessagesViewController.swift:163`):

```swift
if isInitialLoad {
    scrollToBottom(animated: false)                       // jump to bottom, no animation
} else if isNewMessage {
    if lastGroup.isMessagesGroupSentByCurrentUser {
        scrollToBottom()                                  // my message: always
    } else if nearBottom && !userScrolling {
        scrollToBottom()                                  // someone else's: only if near bottom
    }
} else if isPinnedToBottom && !userScrolling {
    scrollToBottom()                                      // in-place bottom growth: re-pin
}
```

`isNewMessage` compares `state.messages.lastMessageId` to the previous last id.

Gating flags:

- `isUserInitiatedScrolling` (`:100`) = `collectionView.isDragging || isDecelerating`.
- `isNearBottom` (`:115`) = `distanceFromBottom <= collectionView.frame.height`
  (within one screen).
- `isPinnedToBottom` (`:127`) is a **latched** flag, updated in
  `handleScrollViewDidScroll` (`:1305`) as
  `distanceFromBottom <= Constant.pinnedToBottomTolerance` (8pt). Being latched
  (not a live distance check) means it answers "was the user pinned *before* this
  update?", so read receipts / reactions / typing growth never yank a user who
  had scrolled up back to the bottom.

### Long vs. short scroll

`scrollToBottom(animated:completion:)` (`:913`) flushes pending insets, computes
`contentOffsetAtBottom` clamped to `lowestOffset = -adjustedContentInset.top`
(not zero — sheet hosts inset content off the top), and early-returns if within
0.5pt. Then:

- `performLongScrollToBottom` (`:979`) for jumps larger than one screen — a
  `ManualAnimator` (`Helpers/ManualAnimator.swift`, a `CADisplayLink`-driven
  custom-duration animator) over 0.25s ease-in-out, because UIKit can't set a
  custom scroll duration.
- `performShortScrollToBottom` (`:995`) otherwise — `UIView.animate` +
  `setContentOffset(animated: true)`.

There is **no floating "scroll to bottom" button**; scrolling is entirely
programmatic, surfaced to hosts through the representable's trigger closure.

### Top pagination ("load previous")

`scrollViewDidScrollToTop` (`:1292`) and `handleScrollViewDidScroll` (`:1301`)
trigger `loadPreviousMessages()` when
`contentOffset.y <= -adjustedContentInset.top` (the very top), gated so it
doesn't fire during initial/previous loads or programmatic scrolls.
`loadPreviousMessages` (`:891`) no-ops if `hasLoadedAllMessages`, else inserts
`.loadingPreviousMessages` and calls the host closure; the flag clears on the
next update (the repo may decide there are no more and never emit again). The
custom layout's offset compensation keeps the visible content stationary while
the older messages insert above.

### Keyboard

The controller is a `KeyboardListenerDelegate` (`:1387`, registered in
`setupUI`). `keyboardWillChangeFrame` (`:1388`) stashes the frame change, inserts
`.changingKeyboardFrame`, computes the new bottom inset via
`calculateNewBottomInset` (`max(keyboardInset, bottomBarHeight)` in the
collection view's coordinate space), and — if the inset is growing — sets
`pendingScrollToBottomAfterKeyboard`. `keyboardDidChangeFrame` clears the flag
and performs the deferred scroll. `updateCollectionViewInsets(to:with:)` (`:1524`)
animates `contentInset.bottom` inside `performBatchUpdates` while restoring a
position snapshot so content doesn't jump. `keyboardDismissMode = .interactive`.

### Sheet hosts and safe area

`ignoredSafeAreaRegions` is chosen in `MessagesView.body` as
`hostsBottomBar ? .all : .container` (`MessagesView.swift:146`): when the
controller owns its bar it does the keyboard math itself, so SwiftUI must not
also inset (double-counting); external-bar hosts do the opposite. The controller
mirrors this with `applyContentInsetAdjustmentBehavior` (`.always` when it hosts
its own bar, `.never` otherwise) and adds `additionalSafeAreaInsets.top =
topContentInset` for hosts that float chrome over the list. `clippedTopOverflow`
plus a latched `shortContentTopSlack` rest short content against the bottom via a
top inset (rather than offsetting item frames, which caused a recursive
self-sizing crash). Bottom-bar-height writes are sometimes deferred one runloop
tick to avoid a re-entrant-layout assertion crash when a sheet relayout arrives
inside a UIKit layout pass.

---

## 10. Gestures, context menu, reactions, swipe-to-reply

The message context menu is **fully custom** — raw `UIGestureRecognizer`s plus a
SwiftUI overlay. It is **not** `UIContextMenuInteraction`, not SwiftUI
`.contextMenu`, and there is no `UITargetedPreview`.

### Gesture detection

`MessageGestureModifier` (`MessagesListView/MessageContextMenuWrapper.swift:21`),
applied to every bubble via `.messageGesture(...)`, overlays a UIKit
`GestureOverlayView` that installs **five raw recognizers** on a custom
`GesturePassthroughView`:

- `UIPanGestureRecognizer` → swipe-to-reply.
- `UILongPressGestureRecognizer` (`minimumPressDuration = 0.5`) → context menu.
- `UITapGestureRecognizer` (2 taps) → double-tap react.
- `UITapGestureRecognizer` (1 tap, `require(toFail: doubleTap)`) → single tap
  (open invite / agent share / attachment / avatar per content type).
- `UILongPressGestureRecognizer` (`minimumPressDuration = 0`) → a press tracker
  driving the scale-down "pressed" feedback.

`GesturePassthroughView.hitTest` (`:376`) lets taps fall through to tappable
links (`LinkHitTestable`) and honors `excludedFrames` (avatars, reaction pills)
so bubble gestures don't eat them. The press-scale grows the bubble to `1.03`
(anchored to the sender's edge, `.easeInOut(0.25)`), and only activates after
0.15s and only if the scroll view isn't dragging. The long-press handler fires a
`UIImpactFeedbackGenerator(style: .medium)` and calls `contextMenuState.present(...)`.

### Presentation state

`MessageContextMenuState`
(`MessagesListView/MessageContextMenu/MessageContextMenuState.swift`) is an
`@Observable` holding `presentedMessage`, `bubbleFrame`, `bubbleStyle`,
`isOutgoing`, and `presentedSegment` (`.whole` / `.splitText` / `.splitLink`, so
a text message with an edge link presents only the pressed sub-cell). It is owned
by `ConversationView` so the surrounding pager can react to it (below).

### The menu UI and animation

`MessageContextMenuOverlay`
(`MessagesListView/MessageContextMenu/MessageContextMenuOverlay.swift`) renders as
a SwiftUI `.overlay` in `MessagesView`, suppressed when the host renders the menu
at its own root (the conversation sheet, to avoid clipping). It layers, in a
`ZStack`:

- **Background dimming** — `Color.black.opacity(0.15)` + `.ultraThinMaterial`,
  tap-to-dismiss.
- **Reactions bar** — a Liquid-Glass capsule
  (`GlassEffectContainer` / `.glassEffect(.regular.interactive(), in: .capsule)`)
  that scales `0.01`→`1.0` from the bubble to a floating drawer above it (spring
  `response 0.28`, `dampingFraction 0.78`), with staggered emoji entrance (each
  emoji blur `10`→`0`, scale `0`→`1`, rotation `-15°`→`0`, delayed
  `0.025 * index`).
- **Action menu** — Reply / Copy / Share / Save rows in a rounded glass card,
  scaling from the bubble's top corner; Reply is delayed 0.22s after dismiss.
- **Bubble preview** — a live re-render of the pressed bubble that springs from
  its source rect to a computed end rect, with a scaling drop shadow.

Drag-to-dismiss (`DragGesture(minimumDistance: 10)`) dismisses past a 150pt
threshold; the menu and bar follow at `0.6` ratio and the dim fades by drag
progress. If the source cell has scrolled away, dismissal "poofs" (blur + fade +
scale) instead of flying back.

### Pager lock during the menu

While the menu is up, `MessagesView` fades and disables the composer, and
`ConversationView` disables the horizontal tab pager:
`isPagingDisabled = contextMenuState.isPresented || agentContextMenuState.isPresented`
applied via `.scrollDisabled(...)` (`Convos/Conversation Detail/ConversationView.swift:1393`).
This is also why the representable bounces the collection view's pan recognizer
(§3) — so a swipe begun mid-press doesn't drag the user out of the conversation.

### Reactions

- **Double-tap to react** fires `UIImpactFeedbackGenerator(style: .light)` and
  toggles the ❤️ (or the message's single existing emoji).
- **From the reactions bar**, `selectReaction` pops the emoji (scale
  `1.0`→`1.2`→`1.0`), collapses the drawer, and auto-dismisses.
- **Custom emoji** via the "+" button toggles the system emoji keyboard
  (`Reactions/EmojiPickerView.swift`, a `UIKeyInput` `UIViewRepresentable` with
  `textInputMode = .emoji`).
- **Display** on bubbles is `Reactions/ReactionIndicatorView.swift` — a pill below
  the bubble; newly added emojis stagger in (blur/scale/rotation, `0.04 * index`).
  It is wired in `MessagesGroupView.reactionRow` using the **live** reactions so
  the height change lands inside the UIKit batch update.
- **The full breakdown** ("who reacted") is `ReactionsDrawerView` (app target),
  opened by tapping the pill (`onTapReactions`). A separate expandable capsule
  component lives in `Reactions/MessageReactionsView.swift`.

### Swipe-to-reply

The pan recognizer (`MessageContextMenuWrapper.swift`) begins only on a
predominantly-horizontal right-swipe, and disables the enclosing scroll view's
pan while active. It rubber-bands past a 60pt threshold, fires
`UIImpactFeedbackGenerator(style: .medium)` at the crossing, shows an
`arrowshape.turn.up.left.fill` indicator that scales/fades with progress, and on
release springs back and fires `onReply` only if it naturally ended past
threshold. A `swipeCancellationToken` lets the pager cancel an in-flight swipe
without firing a reply when the page changes
(`ConversationView.swift:777`). Long-pressing a reply-parent thumbnail
(`ReplyReferenceView.swift`) presents that parent with a medium haptic.

### Haptics inventory (messages package)

- `.light` — double-tap to react (`MessageContextMenuWrapper.swift:147`).
- `.medium` — long-press to open the menu (`:153`); swipe crossing the reply
  threshold (`:494`); long-pressing a reply parent (`ReplyReferenceView.swift:332`).
- The explode/countdown control uses `.light`/`.heavy` impacts and an `.error`
  notification (`ExplodeButton.swift`).

All haptics are inline `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`
(no shared haptics manager).

---

## 11. Insertion / update / deletion animations

Two cooperating systems produce the "message rises and fades into place" effect.

### Layout level (the cell slide)

`DefaultMessagesLayoutDelegate`:

- `initialLayoutAttributesForInsertedItem` (`:259`): sets `alpha = 0`; for an
  inserted `.messages` item shifts `center.y += 120` (`applyMessageAnimation`,
  `:326`); for `.date` / `.update` separators shifts `center.y += 40` and scales
  to `0.1`. The new row starts 120pt lower and fades/slides up.
- `finalLayoutAttributesForDeletedItem` (`:282`) mirrors this for removals,
  reading `oldSections` for the pre-delete geometry.

`MessagesCollectionLayout` supplies these through
`initialLayoutAttributesForAppearingItem` (`:807`) and
`finalLayoutAttributesForDisappearingItem` (`:856`), which undo the total
content-offset compensation, apply the delegate hook, and — crucially — stash a
live copy in `attributesForPendingAnimations` so that if the cell self-sizes
mid-animation, the animation's start/target frames update instead of visibly
jumping from the estimated height. Reloaded items additionally get `alpha = 0` +
a scale-0 transform.

### SwiftUI level (per-message spring)

`MessagesGroupItemView`:

- `MessageAppearanceModifier` (`:514`): a bubble's initial pose is
  `scaleEffect(0.9)`, `rotationEffect ±0.05 rad` (direction by incoming/outgoing),
  `offset(x: ±20, y: 40)`.
- `.onAppear` (`:113`): if the message `origin == .inserted`, springs the pose
  away with `.spring(response: 0.35, dampingFraction: 0.8)`; otherwise
  `.animation(.none)` so pre-existing history does not animate. Guarded so it
  fires once.

`MessagesGroupView` mirrors this at the group level (sender label and avatar
slide/blur in) and routes appended content through an `animatedGroup` mirror
updated only in `onChange` (`:762`), so height changes land unanimated and the
controller reveals them via an animated scroll (§7 out-of-band growth). Reaction
and read-receipt rows use the same mirrored-`onChange` trick so their height
change lands inside the UIKit batch.

Content updates (reactions, status, edits) reach the cell as `reconfigureItems`
(§4), so they animate as in-place SwiftUI transitions
(`.blurReplace`, scale/opacity) rather than a cell teardown.

### Send flow

On send, `MessagesView` calls the scroll-to-bottom trigger before
`onSendMessage()`. There is **no** "message flies up out of the composer"
transition — the send animation is the 120pt layout slide-up + the SwiftUI spring
plus an animated scroll-to-bottom. Optimistic messages carry `origin == .inserted`
to gate the animation.

### Typing / thinking indicators

`PulsingCircleView` (`PulsingCircleView.swift`) is the dot-animation engine:
`.typingIndicator` = 3 gray dots (size 10, 0.6s, `easeInOut.repeatForever`,
staggered by `index * duration / count`); `.thinkingIndicator` = a single dot
(1.2s, opacity 0.4–1.0). `TypingIndicatorBubbleView` wraps the dots in a tailed
container; `TypingIndicatorView` adds overlapping ringed typer avatars for
multi-typer. Indicators enter/leave with
`.transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))`.

---

## 12. Constants and gotchas

### Constants split

- `Messages View Controller/Constants.swift` — bubble geometry: `maxWidth 0.75`,
  `bubbleCornerRadius 20`, `minimumPressDurationForReactions 0.15`, and an iPad
  bubble-width cap (`maxBubbleRowWidth = 440 - 16`).
- A separate `enum Constant` nested in `MessagesViewController`
  (`MessagesViewController.swift:1548`) — scroll/keyboard tuning:
  `pinnedToBottomTolerance 8`, `outOfBandGrowthRevealThreshold 12`, and fallback
  delays for context-menu inset restoration and composer settle.

### Re-entrant layout crash avoidance

Several mechanisms exist purely to avoid UIKit assertion crashes and open-transition
flicker: the `SetActor` gating (§5), the deferred bottom-bar-inset updates (§9),
the quiescent `layoutSubviews` pass (§7), and the exact-sized self-sizing
exclusion (§7). Treat these as load-bearing — they encode hard-won fixes, not
incidental caution.

### Inactive / dead code to be aware of

- `Message Models/TypingState.swift` defines `enum TypingState { case idle, typing }`
  but nothing references it — legacy/dead.
- The typing-indicator *path* is fully wired (enum case, `CellFactory` branch,
  `TypingIndicatorCollectionCell`, delegate sizing) but **no site currently
  constructs `.typingIndicator(typers:)` into the messages array**, so the
  indicator is presently inactive. It would diff in/out like any other item if a
  producer appended it. (The other `.typingIndicator` symbols found in the
  codebase — in `HiddenMessagesView`, `StreamProcessor`, and the hidden-message
  debug helpers — are an unrelated hidden-message *reason*, not this item case.)

---

## Appendix: how a single reaction reaches the screen

A concrete trace, to tie the layers together:

1. A reaction message arrives over XMTP and is persisted; GRDB's
   `ValueObservation` fires.
2. `MessagesRepository`'s throttled publisher emits a new
   `ConversationMessagesResult` (≤ ~3/sec).
3. `MessagesListProcessor` rebuilds the affected `MessagesGroup` — same `id`,
   but its `rawMessages`/reactions differ, so its value changes.
4. `MessagesListRepository` pushes the new `[MessagesListItemType]`;
   `ConversationViewModel.messages` is reassigned on the main queue.
5. SwiftUI re-renders `MessagesView`; the representable sets
   `MessagesViewController.state`.
6. `processUpdates` builds one `MessagesCollectionSection`; `performUpdate`
   computes a `StagedChangeset`. The changed group has the same
   `differenceIdentifier` but is not `isContentEqual`, so it lands in
   `elementUpdated`.
7. `UICollectionView+DifferenceKit.reload(using:)` calls `reconfigureItems(at:)`
   on both the collection view and the custom layout.
8. The cell's `setup(item:config:)` re-runs, updating the `UIHostingConfiguration`
   in place; `ReactionIndicatorView` animates the new emoji in.
9. The reaction row's added height self-sizes; the layout compensates the content
   offset (or reveals it via an animated scroll if the user was pinned to the
   bottom), keeping the reading position stable.

[ChatLayout]: https://github.com/ekazaev/ChatLayout
[DifferenceKit]: https://github.com/ra1028/DifferenceKit
