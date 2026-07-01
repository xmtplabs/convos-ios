# Plan: split the image cache into a URL-keyed byte cache + a read-only continuity hint

- Status: draft for review
- Date: 2026-06-26
- Related:
  - `docs/postmortems/2026-06-26-profile-avatar-cache-pingpong.md`
  - `docs/specs/profile-contact-identity-model.md`

## Goal

Today `ImageCache` is secretly **two caches fused into one identity-keyed slot**,
and that fusion is the root of the avatar clobber / oscillation / stuck-on-old
bug class:

- It stores "the bytes" and "the latest image to show for an identity" in the
  same place, keyed by `imageCacheIdentifier` (e.g. `inboxId`).
- `loadImage(for: object)` reconciles that single mutable slot to whatever
  `imageCacheURL` the caller passes. Any caller — including a stale one — can
  overwrite the slot, and the cache has no clock or authority to know whether a
  caller's URL is newer or older than what it holds.

That single property gives us both the nice behavior (show *something* for a
person/group instantly, even mid-update) and the bug (a stale caller drags the
shared slot backward, and views fight over it). They are the same mechanism, so
you cannot keep one without the other.

This plan splits them apart.

## The core reframing: two caches

1. **Authoritative byte cache — `url -> bytes`, immutable, URL-keyed.** Owns
   truth. A given URL always pairs with one encryption key and decrypts to the
   same bytes, so `url -> decrypted bytes` is a pure function and a safe key.
   Two URLs are two independent entries, so there is **no shared identity slot to
   clobber** — a stale caller fetches its own (old) URL's entry and never touches
   a different URL's entry. No clobber, no oscillation, no stuck-on-old, and the
   `recentlyFetched` stopgap guard is no longer needed.

2. **Read-only continuity hint — `identity -> last-shown image`, disk-backed.**
   This is the "show the previous image until the new one downloads" behavior we
   rely on, demoted to a pure display fallback. It is consulted **only** as the
   placeholder while the current URL is being fetched. It is written as a side
   effect when a URL-keyed image successfully displays for that identity. It
   **never triggers a fetch and never decides the canonical URL.**

The distinction that makes this safe: **showing a stale face as a placeholder is
fine; fetching and installing a stale URL as the canonical entry is the bug.**
The current cache does the latter to achieve the former. After the split, the
byte cache does only truth (URL-keyed, immutable) and the hint does only
continuity (read-only, never fetches).

## One call surface — call sites do not change

The elegant part: the `ImageCacheable` object already carries **both** keys —
`imageCacheURL` (truth) and `imageCacheIdentifier` (continuity key). So callers
keep expressing the same intent — "show this object's image" — and all the
truth-vs-continuity orchestration moves *inside* the cache. No call site branches
on `contains`, and the hundreds of `(...).cachedImage(for: object)` / `image(for:
object)` / `loadImage(for: object)` call sites stay identical.

```swift
// Sync "what do I show right now": URL hit, else continuity placeholder.
func image(for object: any ImageCacheable) -> UIImage? {
    if let url = object.imageCacheURL, let img = byteCache[key(url)] {
        lastShown[object.imageCacheIdentifier] = img   // keep the hint fresh
        return img
    }
    return lastShown[object.imageCacheIdentifier]        // stale bridge (may be nil)
}

// Async authoritative resolve: URL-keyed memory -> disk -> network(+decrypt).
func loadImage(for object: any ImageCacheable) async -> UIImage? {
    guard let url = object.imageCacheURL else { return nil }
    let img = await fetchByURL(url, decrypting: object)   // deduped by url
    if let img { lastShown[object.imageCacheIdentifier] = img }
    return img
}
```

The `.cachedImage(for:into:)` modifier keeps its current shape; continuity falls
out for free:

```swift
.onAppear { binding.wrappedValue = cache.image(for: object) }      // url hit OR last-shown
.task(id: object.imageCacheURL) {
    binding.wrappedValue = cache.image(for: object)                // re-seed on url change -> old bridges
    if let resolved = await cache.loadImage(for: object) {
        binding.wrappedValue = resolved                            // swap when truth arrives
    }
}
.onReceive(cache.updates(for: object.imageCacheURL)) { ... }
```

Walkthrough (the group-image case the current design handles and we must
preserve): the URL flips `g1 -> g2`, `.task` re-fires, `image(for:)` looks up
`g2` in the byte cache -> miss -> returns `lastShown[conversationId]` = the old
group photo -> shown instantly, no blank; then `loadImage` downloads+decrypts
`g2` and swaps. Identical to today's UX, but the byte cache never had a shared
slot to clobber.

## Scope

In scope (the re-fetchable, URL-addressable path):

- `image(for:)` / `loadImage(for:)` and the `ImageCacheable.imageCacheURL` flow
  used by avatars, conversation/group images, link previews, invite images.
- The memory (`NSCache`) + evictable disk byte tier.
- The new read-only continuity hint.
- `cacheUpdates` notifications.
- `EncryptedImagePrefetcher`.
- The `.cachedImage(for:into:)` modifier.

Out of scope (leave as-is, to bound blast radius):

- The persistent attachment tier (`cacheData(_:for:storageTier:.persistent)`,
  `removePersistentImages`, etc.). Non-re-fetchable chat photos have no shared
  slot problem and can stay identifier-keyed.
- Protocol/wire changes (single-`RemoteAttachment` avatar) and the Contacts
  canonical-URL work — tracked in the identity spec; complementary, see Risks.

## What gets deleted vs added

Deleted (machinery that existed only to manage the identity->URL coupling):

- `URLTracker` entirely: `trackedURLs`, `peek`, `track`, the `.url` sidecar
  persistence, and the `recentlyFetched`/`recordFetched` stopgap guard. The disk
  filename becomes the URL hash; there is nothing to "track."
- `scheduleBackgroundRefresh` and the URL-drift branches in `loadImage` (a
  different URL is just a miss -> fetch).
- `urlChangeSubject` / `urlChanges` / `hasURLChanged` and the `peek.changed` /
  `shouldRefresh` logic.

Added:

- The read-only `lastShown` continuity hint (`identity -> image`), disk-backed.

Note these are different things: the deleted `.url` **sidecars** were
identity->URL mappings for drift detection (part of the clobber machinery). The
added **continuity hint** is identity->last-displayed-image, read-only for
display. We remove the former and add the latter.

Kept: `loadingTasksLock` (network dedup, already URL-keyed); disk LRU cleanup
(operates on files regardless of key meaning; the sidecar-pairing step goes away
with the sidecars).

## Key decisions to lock before coding

1. **Key format.** Proposal: `sha256(url.absoluteString)` for the disk filename;
   `url.absoluteString` (or its hash) as the `NSCache` key. Decide whether to
   hash the memory key too.
2. **Encrypted + plain under one URL key space.** Both decode to bytes stored
   under the URL key. Confirm no URL is ever fetched with two different keys
   (true today: per-conversation URLs are 1:1 with their key); add an
   assertion/log if a second key is seen for an already-cached URL.
3. **Continuity hint persistence + size.** Disk-backed so cold launch after a
   remote change still bridges with the old image. Decide format (small JPEG
   thumbnail per identity) and that it shares the LRU/size budget sensibly.
4. **Owner pre-upload preview.** With URL-keying there is no URL at stage time.
   Preserve instant display of your own just-picked photo (see Edge cases).

## Phased implementation

**Phase 0 - Audit.** Enumerate every caller of `ImageCache` / `ImageCacheProtocol`
and every `ImageCacheable` conformance (`Profile`, `Conversation`, `LinkPreview`,
`MessageInvite` in `ImageCacheableExtensions.swift`, plus `Contact`). Classify
each as URL-path (migrate) or persistent/identifier-path (leave). Output a short
table so nothing is missed.

**Phase 1 - URL-keyed byte cache.** Add `key(for url: URL)`. Convert memory cache,
disk filenames, and the fetch paths (`fetchByURL` = the encrypted/plain
download+decode+cache) to key by URL. Update `image(for:)` / `loadImage(for:)` /
`imageAsync` internals to resolve the URL from the passed object and key by it.

**Phase 2 - Continuity hint (required, not optional).** Add the disk-backed
`lastShown` store keyed by `imageCacheIdentifier`. Write it on every successful
display/resolve. Read it only as the fallback in `image(for:)`. It never fetches
and never sets canonical state.

**Phase 3 - Delete the tracker + stopgap.** Remove `URLTracker`, sidecars,
`recentlyFetched`/`recordFetched`, `scheduleBackgroundRefresh`, drift branches,
`urlChangeSubject`, `hasURLChanged`. Re-point `cacheUpdates` to carry the URL key.

**Phase 4 - Modifier.** Update `.cachedImage(for:into:)` to the shape above:
`onAppear`/`.task` seed from `image(for:)` (so last-shown bridges), `.task(id:)`
keyed on `object.imageCacheURL`, `.onReceive` filtered on the URL key, never reset
the binding to nil on a miss.

**Phase 5 - Prefetcher.** Update `EncryptedImagePrefetcher` to cache/check by URL
key instead of `hydratedProfile.imageCacheIdentifier`.

**Phase 6 - Owner upload preview.** Implement the chosen instant-preview path
(Edge cases).

**Phase 7 - On-upgrade cleanup.** The disk filename scheme changes
(`sha256(identifier)` -> `sha256(url)`), so existing byte entries become
unreachable. One-time wipe of the evictable image cache directory on first launch
after upgrade (persistent attachment dir untouched). The new continuity hint
starts empty and fills as images display.

**Phase 8 - Tests + cleanup.** See Testing; remove now-dead stopgap code; update
the identity spec to reference this as the cache half of the fix.

## Edge cases

- **Owner pre-upload preview.** Today `prepareForUpload` caches the picked image
  under the identifier before any URL exists. Options:
  1. Pass the picked `UIImage` to the view as `placeholderImage` /
     `profileImage` for the upload duration (both `ProfileAvatarView` and
     `AvatarView` already accept a placeholder); on completion the URL load takes
     over. Cleanest.
  2. Seed the `lastShown` hint for that identity with the picked image at stage
     time, so any view bridges to it immediately. Reuses the hint; also fine.
- **Clearing an avatar (url nil).** View shows placeholder/monogram; old URL
  bytes age out via LRU. Decide whether to also clear `lastShown` for that
  identity on an explicit clear, so a removed avatar doesn't keep bridging to the
  old face (probably yes for an explicit clear; no for a transient nil).
- **Same URL, multiple objects.** Naturally deduped — one entry, one fetch.
- **Same image, different per-conversation URLs (pre-canonicalization).** Caches
  once per URL (up to N x M decrypted copies), bounded by the existing disk LRU
  and memory limits. The known storage cost of URL-keying without canonical URLs;
  this is why the canonical-URL-in-Contact work pairs with it.
- **URL reuse with changed content.** Not possible for content-addressed avatar
  uploads (unique UUID + fresh salt/nonce). Only `LinkPreview` has a mutable URL;
  a stale preview for its cache lifetime is acceptable/cosmetic.

## Testing

- URL-keyed get / set / disk round-trip / LRU eviction with URL-hash filenames.
- **Regression for this whole saga:** two `ImageCacheable` values with the same
  `imageCacheIdentifier` but different URLs produce two independent byte entries;
  loading the old URL never changes the new URL's bytes (no clobber); fetch count
  is bounded (no oscillation).
- **Continuity:** after a remote URL change, a *fresh* view first shows the
  `lastShown` image for that identity (no placeholder blink), then swaps to the
  new URL once resolved — including across a simulated cold launch (hint is
  disk-backed).
- **No blink on in-place change:** a view whose URL flips a->b keeps showing a
  until b resolves.
- Encrypted fetch+decrypt cached and re-served by URL without re-fetch.
- `lastShown` is never consulted to choose a fetch and never overrides a resolved
  URL image once available.
- Clearing an avatar: placeholder, no crash, hint behavior per the decision above.
- Owner upload: picked image visible immediately (Phase 6 path).
- Same URL across two objects: a single network/decrypt serves both.

**Per-`ImageCacheable` type coverage.** Exercise each production conformance
through the new `image(for:)` / `loadImage(for:)` / `.cachedImage(for:)` API.
Three are encrypted (need `key/salt/nonce` at fetch); two are plain. For a 1:1/DM
the same person is represented by `Profile`, `Conversation`, and `Contact` at
once, so the dedup/continuity cases must be checked across types, not just within
one.

- `Profile` — member & agent avatars, encrypted (`ImageCacheableExtensions.swift:3`):
  correct current avatar across surfaces (message bubbles, member list, read-by
  drawer, contact card); the no-clobber regression (two URLs for one `inboxId`);
  continuity bridge + no blink on change; removal; dedup across many simultaneous
  avatar views of one person.
- `Conversation` — group images and DM peer avatars, encrypted
  (`ImageCacheableExtensions.swift:58`): group-image continuity (old shown while
  the new one downloads, including across a simulated cold launch); both the
  `customImage` and `profile(member)` branches resolve; the DM case shares the
  peer's URL (must dedup with `Profile`, not clobber).
- `Contact` — contacts-UI default avatar, encrypted (`Contact.swift:398`):
  renders in contacts list / picker / detail; its `contact:` identifier differs
  from `Profile`'s, so confirm the byte cache still dedups by URL (no double
  fetch of the same image) and the continuity hint behaves under that key.
- `LinkPreview` — link preview image, plain/unencrypted
  (`ImageCacheableExtensions.swift:48`): renders by URL; mutable-URL caveat — a
  changed preview at the same link does not refresh until the entry is evicted
  (assert no crash / no clobber; accept the staleness).
- `MessageInvite` — invite-card image, plain/unencrypted
  (`ImageCacheableExtensions.swift:38`): renders by URL.
- Test conformances `TestImageCacheable` / `EncryptedCacheable`
  (`ImageCacheTests.swift`) updated to the URL-keyed API; existing suite green.

## Rollout / migration

- No schema or wire migration; memory cache is ephemeral; byte cache re-fetches
  lazily after the one-time cleanup (Phase 7); the continuity hint starts empty.
- Optional behavior flag for one release (the cache is on every avatar render) to
  keep a fast revert path.
- Reversible: changes are contained to `ImageCache` + the modifier + prefetcher.

## Risks

- **Storage/work amplification before canonical URLs** (N x M decrypted copies +
  redundant decrypts of the same face). Bounded by existing LRU/memory limits but
  real until canonicalization; sequence with the Contacts canonical-URL work or
  accept the interim cost.
- **Continuity hint correctness.** If the hint is written from the wrong image or
  not cleared on explicit removal, a fresh view could briefly bridge to a wrong/
  removed face. Bounded to the pre-load placeholder window (the resolved URL image
  always overrides), and covered by tests, but get the write/clear rules right.
- **Owner preview / no-blink regressions** if Phase 4/6 are botched — covered by
  tests.
- **Reactivity is now upstream-only.** The cache no longer detects URL changes;
  correctness depends on the `Profile`/`Conversation` re-hydrating with the new
  URL (DB -> `ValueObservation` -> re-render), which already drives today's drift
  detection. Confirm every avatar/image surface is driven by an observation that
  re-emits on URL change.

## Why this is the right root fix

The clobber / oscillation / stuck-on-old behaviors all require a shared mutable
slot that callers write by supplying a URL. Splitting the cache removes that
slot: the **byte cache** is immutable and URL-keyed (truth, un-clobberable), and
the **continuity hint** is read-only identity-keyed (the nice "show the previous
image" behavior, with no ability to fetch or set canonical). We keep the UX,
delete the stopgap guard and the URL tracker, and the call sites do not change.
Canonical-URL-in-Contact then makes it storage-efficient and lets one fetch serve
every surface — the two halves of the complete fix.
