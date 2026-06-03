# 1-Pager: Hide Blocked Contacts by Default + "Show blocked" Filter

> **Status**: Draft
> **Author**: Cameron Voell
> **Created**: 2026-06-03
> **Updated**: 2026-06-03

## 1. Tweet Headline

👉 "Blocked contacts no longer clutter your address book by default -- and when you need them, they're one menu toggle away."

## 2. Show, Don't Tell

- 📸 Screenshot / mockup: TBD -- this re-uses the filter menu added in #951.
- 🍿 Loom demo link: N/A
- 🎨 Figma file link: N/A

The existing `ContactsFilter` menu (added in commit 718b1d52 / #951) currently exposes three audience options as a single-select `Picker`, identically in both the browse list and the picker:

```
[Filter icon] -> Menu              (browse list AND picker, today)
    o All
    o People
    o Agents
```

After this change, the **browse list's** menu adds a second region with an independent toggle:

```
[Filter icon] -> Menu              (browse list only, after this PR)
    o All
    o People
    o Agents
    --
    [ ] Show blocked
```

The picker's menu is **unchanged** -- it stays the three-option audience radio. Blocked contacts are always filtered out of the picker; there's no toggle to reveal them.

When `showBlocked` is on in the browse list, the filter icon's "active" tint also fires alongside the existing `ContactsFilter.isActive` check.

## 3. How It Works

The PR layers a new orthogonal toggle on top of the existing audience filter without disturbing its shape.

- **State.** `ContactsViewModel` gains `var showBlocked: Bool = false` with the same `didSet { rebuildSections() }` shape `filter` and `searchQuery` already use. `ContactsPickerViewModel` does **not** gain a parallel toggle -- the picker is a selection surface and blocked contacts are never a valid target, so adding the toggle there only surfaced dimmed unselectable rows that polluted the menu without ever being actionable. The unblock recovery flow lives on the contact card, reachable from the browse list.
- **Filter menu.** `ContactsSearchBar.filterMenu(_:)` keeps the existing `Picker("Filter contacts", selection: filter)` and appends a `Toggle("Show blocked", isOn: $showBlocked)` *only when the caller supplies the binding*. The label-side "active" treatment (`iconColor`) reads as active when either `filter.isActive` or `showBlocked` is true. `ContactsView` passes the binding; `ContactsPickerView` does not, so the picker's menu reads as before (audience radio only).
- **Browse list (`ContactsViewModel`).** The pipeline already calls `visibleContacts() -> filterByAudience -> filterByQuery`. Insert a small `filterByBlocked` step between `visibleContacts()` and `filterByAudience` so blocked rows drop out unless `showBlocked` is on. `contactCount` stays untouched (it represents the unfiltered count today and continues to drive the onboarding empty state).
- **Picker (`ContactsPickerViewModel`).** Unchanged behavior. `isPickable = !isBlocked && isVisibleInContactsList` already excludes blocked rows entirely, and we keep that as both the visibility predicate and the selection-prune predicate. There is no separate visibility-vs-selectability split here.
- **Browse row chrome.** Add a "blocked" pill plus a 0.45 opacity to `ContactRowView` when `contact.isBlocked` so a revealed row reads as different from the rest. The row stays tappable -- the contact card is the entry point for unblock. The picker row (`ContactsPickerRow`) does not need any blocked treatment because the picker never receives blocked rows.

That is the full diff: a 1-line view-model bool per surface, a `Toggle` row appended to the existing menu, a 1-line predicate change in each pipeline, and badge / opacity tweaks on the two row views.

## 4. Who Cares

- **Use case 1 (Cameron):** I blocked a noisy account last month. Every time I open Contacts to start a chat, that account is the first row in the "A" section and I scroll past it. After this change it's gone from the list, and I get it back via the same menu I already use for People/Agents.
- **Use case 2 (Jarod, support):** "Why is my blocked contact still showing up in my contacts" is a recurring confusion. Default-hide kills the bug class.
- **Use case 3 (someone who needs to unblock):** Open Contacts -> tap the filter icon -> flip "Show blocked" -> tap the (dimmed) row -> contact card has the existing Unblock CTA. Two extra taps vs. before, behind a discoverable and reversible affordance.
- **Use case 4 (composer):** The picker already excluded blocked contacts and continues to. The picker is a selection surface; visibility-without-selectability adds menu noise without an actionable payoff. Users who want to inspect blocked contacts open the browse list.

## 5. What It Isn't

- **This is not a new audience filter.** `ContactsFilter` (All / People / Agents) keeps its single-select shape. "Show blocked" is an orthogonal toggle, not a fourth case.
- **This does not change block / unblock plumbing.** The contact card's Block / Unblock CTA and the `ContactsWriter.block(inboxId:)` / `.unblock(inboxId:)` semantics are unchanged.
- **The picker does not get the "Show blocked" toggle.** Blocked contacts are always filtered from the picker. The picker is a selection surface and blocked contacts are never selectable; surfacing them would only add dimmed unselectable rows to the menu. The contact card (reachable from the browse list) is the unblock entry point.
- **This is not persisted.** `showBlocked` resets with the view-model instance, same as `filter` and `searchQuery` today. No `UserDefaults`, no cross-surface sharing.
- **This is not a separate "show only blocked" view.** Blocked contacts only show alongside the rest of the active audience -- the toggle adds them in, it doesn't switch to them.

## 6. FAQ + UAQ

### FAQ (known questions)

1. **Q:** Won't users who already had blocked contacts be confused when they "disappear"?
   **A:** A release-note line is sufficient -- the recovery is one menu toggle away and the filter icon already has the "active" treatment when narrowing, so the affordance is discoverable. No in-app tooltip planned.

2. **Q:** Does the audience filter compose with "Show blocked"?
   **A:** Yes. Agents + show-blocked reveals blocked agents. People + show-blocked reveals blocked humans. All + show-blocked reveals everything. The two predicates are independent.

3. **Q:** What happens to a preselected blocked inboxId in the picker?
   **A:** Same as today: the `applyContacts(_:)` prune is gated on `isPickable` (which still excludes blocked), so the selection is dropped before the user sees the screen. The picker has no "Show blocked" toggle to reverse this.

4. **Q:** Does the search query compose with the new blocked predicate?
   **A:** Yes -- the order is `visibleContacts() -> filterByBlocked -> filterByAudience -> filterByQuery`. A blocked row only matches the search when `showBlocked` is on.

5. **Q:** Does the existing "Suggested agents" section honor the toggle?
   **A:** Suggested agents are non-blocked by construction (the backend never serves a blocked-by-me suggestion), so the section is unaffected. The existing `filter.includesAgents` gate on the section header still applies.

### UAQ (resolved 2026-06-03; left in the doc as a decision log)

- [x] Menu copy: **"Show blocked"**.
- [x] Picker row "blocked" badge: no badge needed -- the picker always filters blocked contacts out, so no blocked row ever reaches `ContactsPickerRow`.
- [x] Browse-row treatment: dim to 0.45 opacity + trailing "blocked" pill (matching the `.colorFillMinimal` capsule the picker uses for "in chat"). **Row stays tappable** -- the tap navigates to `ContactDetailView` (the Unblock CTA lives there), so making the row non-tappable would orphan the recovery flow.

## 7. Counterintuitive Angle

👉 "The hardest thing about blocking someone isn't blocking them -- it's the daily reminder that they exist in your contact list. Default-hide makes block actually mean block."

## 8. Call to Action

- [x] ✅ Build
- [ ] 🧪 Test
- [ ] 🚫 Drop
- [ ] 💬 Debate

**Next steps if approved:**

1. Add `showBlocked: Bool = false` to `ContactsViewModel` with `didSet { rebuildSections() }`. `ContactsPickerViewModel` is not changed.
2. Append a `Toggle` to the existing `ContactsSearchBar.filterMenu(_:)` behind an optional binding. Only `ContactsView` passes the binding; `ContactsPickerView` does not.
3. Wire `filterByBlocked` into `ContactsViewModel`'s rebuild pipeline. The picker's `isPickable` predicate continues to exclude blocked unconditionally.
4. Add the "blocked" pill + opacity treatment to `ContactRowView` for the browse list.
5. Tests: extend `ContactsViewModelTests` with cases for default-hide, toggle-reveals, audience composition, `isFiltering` tracking, and clear-filters reset. `ContactsPickerViewModelTests` already covers the picker's blocked-default behavior; no additions needed there.

## References

- [#951 `feat(contacts): filter list by All / People / Agents`](https://github.com/xmtplabs/convos-ios/pull/951) -- the existing filter menu this PR extends. Commit `718b1d52`.
- `Convos/Contacts/ContactsFilter.swift` -- the audience enum, unchanged.
- `Convos/Contacts/ContactsSearchBar.swift` -- the menu host, gains a second binding.
- `Convos/Contacts/ContactsViewModel.swift`, `Convos/Contacts/ContactsPickerViewModel.swift` -- the two consumers.
- `ConvosCore/Sources/ConvosCore/Storage/Models/Contact.swift` -- `isBlocked` predicate that drives the new gate.
