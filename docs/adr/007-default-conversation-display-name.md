# ADR 007: Default Conversation Display Name and Emoji

> **Status**: Accepted
> **Author**: Jarod
> **Created**: 2026-02-20

## Context

Every Convos conversation needs a display name and avatar, even when no custom name has been set. This is non-trivial because Convos uses per-conversation identities (ADR 002), meaning members are frequently anonymous with no profile name set.

This ADR specifies the algorithms integrators must follow so that all Convos clients display identical default names and emojis for the same conversation.

## Decision

### 1. Display Name Resolution

Given a conversation, resolve its display name using the first matching rule:

| Priority | Condition | Display Name |
|----------|-----------|-------------|
| 1 | Conversation has a non-empty custom `name` | The custom name |
| 2 | Conversation is a DM and the other member has a name | The other member's `displayName` |
| 3 | Conversation is a DM and the other member has no name | `"Somebody"` |
| 4 | Group conversation with no other members | `"New Convo"` |
| 5 | Group conversation with other members | Result of **Member Name Formatting** (section 2) |

"Other members" means all members excluding the current user.

A member's `displayName` is their profile `name` if set, otherwise `"Somebody"`.

### 2. Member Name Formatting

Given a list of other members' profiles, produce a formatted string as follows:

**Step 1: Partition members.**

- `namedProfiles`: members where `name` is non-nil and non-empty, mapped to their `displayName`, then sorted alphabetically (lexicographic, case-sensitive)
- `anonymousCount`: count of members where `name` is nil or empty

**Step 2: Apply formatting rules.**

Let `MAX_NAMES = 3` and `totalCount = namedProfiles.count + anonymousCount`.

**Case A: No named members.**

| anonymousCount | Result |
|---------------|--------|
| 0 | `""` (empty string) |
| 1 | `"Somebody"` |
| 2+ | `"Somebodies"` |

**Case B: Total count fits within MAX_NAMES.**

Build a list of all display items: the sorted named profiles, plus `"Somebody"` (if `anonymousCount == 1`) or `"Somebodies"` (if `anonymousCount > 1`). Then join:

| Item count | Separator | Example |
|-----------|-----------|---------|
| 1 | (none) | `"Alice"` |
| 2 | ` & ` | `"Alice & Bob"` or `"Alice & Somebody"` |
| 3 | `, ` | `"Alice, Bob, Somebody"` |

**Case C: Total count exceeds MAX_NAMES.**

Take the first `MAX_NAMES` sorted named profiles. Calculate `othersCount = totalCount - MAX_NAMES`. Format as:

```
"{name1}, {name2}, {name3} and {othersCount} other"    // othersCount == 1
"{name1}, {name2}, {name3} and {othersCount} others"   // othersCount > 1
```

Anonymous members are counted in `othersCount` but never listed individually.

**Examples:**

| Members (names) | Output |
|----------------|--------|
| `["Alice"]` | `"Alice"` |
| `["Bob", "Alice"]` | `"Alice & Bob"` |
| `["Carol", "Alice", "Bob"]` | `"Alice, Bob, Carol"` |
| `["Dave", "Carol", "Alice", "Bob"]` | `"Alice, Bob, Carol and 1 other"` |
| `["Eve", "Dave", "Carol", "Alice", "Bob"]` | `"Alice, Bob, Carol and 2 others"` |
| `[nil]` | `"Somebody"` |
| `[nil, nil]` | `"Somebodies"` |
| `["Alice", nil]` | `"Alice & Somebody"` |
| `["Alice", nil, nil]` | `"Alice & Somebodies"` |
| `["Alice", "Bob", nil]` | `"Alice, Bob, Somebody"` |
| `["Alice", "Bob", "Carol", nil]` | `"Alice, Bob, Carol and 1 other"` |

### 3. Deterministic Emoji Selection

Every conversation has a deterministic default emoji derived from its `clientConversationId` (the XMTP group ID). All clients must produce the same emoji for the same conversation.

**Algorithm:**

```
input  = clientConversationId (UTF-8 encoded)
hash   = SHA-256(input)
index  = hash[0] % 80          // first byte of the hash, modulo pool size
emoji  = EMOJI_POOL[index]
```

**Emoji pool (80 items, in order):**

```
Index  0-9:   🥫 🎸 🎨 🎯 🎪 🎭 🎬 🎤 🎧 🎹
Index 10-19:  🎺 🎻 🪘 🪗 🎲 🎮 🧩 🪀 🪁 🧸
Index 20-29:  🪆 🔮 🧿 🪬 🎰 🛸 🚀 ⚓️ 🧲 💎
Index 30-39:  🌵 🌊 🍄 🌸 🌈 🌻 🌴 🌲 🍀 🌾
Index 40-49:  🪻 🪷 🪹 🪺 🌙 ⭐️ 🌍 🔥 💧 🌪️
Index 50-59:  🦊 🐙 🦋 🐢 🦩 🦄 🐋 🦈 🦑 🐠
Index 60-69:  🦜 🦚 🦢 🦉 🦇 🐝 🐌 🦎 🐲 🦕
Index 70-79:  🍕 🌮 🍩 🍦 🥑 🍎 🍋 🍇 🥝 🍒
```

The pool is intentionally small (80 items) and curated to avoid culturally sensitive or ambiguous symbols. Collisions are expected and acceptable.

### 4. Avatar Type Resolution

Given a conversation, resolve which avatar to display using the first matching rule:

| Priority | Condition | Avatar |
|----------|-----------|--------|
| 1 | Conversation has a custom `imageURL` | The custom image |
| 2 | Exactly 1 other member | That member's profile avatar |
| 3 | 0 other members, or no member has an avatar | The deterministic emoji (section 3) |
| 4 | 2+ other members with at least one avatar | Clustered avatar of up to 7 member profiles |

For clustered avatars, members are sorted with avatar-bearing members first, then named members, then by `inboxId` lexicographically. Take the first 7 after sorting.

### 5. Fully Anonymous Detection

A conversation is "fully anonymous" when:
- It has at least 1 other member (excluding the current user), **and**
- None of those members have a non-empty profile name

A conversation with 0 other members is not fully anonymous; it's considered new. Clients may use this flag to adjust presentation (e.g., showing the emoji more prominently).

### 6. Constants

| Name | Value | Usage |
|------|-------|-------|
| `maxDisplayNameLength` | 50 | Maximum characters for a custom conversation name |
| `maxDisplayedMemberNames` | 3 | Named members shown before "and N others" truncation |

## Consequences

### Positive

- All Convos clients display identical names and emojis for the same conversation
- Anonymous members read as intentional ("Somebody") rather than broken ("Unknown")
- Deterministic emoji gives every conversation a stable visual identity without requiring user action
- Alphabetical sorting keeps names stable as members update profiles

### Negative

- Display names change as members join, leave, or update their profile names
- 80-emoji pool means collisions across conversations within the same account
- "Somebodies" is unconventional English; integrators should not localize it differently without coordinating across clients

## Implementation Notes

- The emoji pool and SHA-256 algorithm are the critical cross-client contract. If an integrator gets these wrong, conversations will show different emojis on different clients.
- The name formatting algorithm must match exactly, including separator choice (`&` vs `,` vs `and`), to avoid jarring differences across platforms.
- All logic is computed from current member state; nothing is persisted. Names and emojis update reactively as members change.

**Reference implementation (iOS):**
- `ConvosCore/Sources/ConvosCore/Storage/Models/Conversation.swift` - display name and avatar resolution
- `ConvosCore/Sources/ConvosCore/Storage/Models/Profile.swift` - member name formatting
- `ConvosCore/Sources/ConvosCore/Utilities/EmojiSelector.swift` - emoji selection
- `ConvosCore/Sources/ConvosCore/Constants/NameLimits.swift` - constants
- `ConvosCore/Tests/ConvosCoreTests/DefaultConversationDisplayTests.swift` - test vectors

## Related Decisions

- [ADR 002](./002-per-conversation-identity-model.md): Per-conversation identities explain why members are often anonymous
- [ADR 005](./005-profile-storage-in-conversation-metadata.md): Profile storage determines when member names are available
