# Long Message Handling

> Status: Approved -- iOS implementation in review.

## Why
Synchronously laying out unbounded message text (SwiftUI `Text` / CoreText) was the largest iOS UI-hang cluster. This is a performance fix that doubles as product behavior. Non-blocking and reversible.

## Display rules
Classify a message body by length with a cheap character-count check (never measure or lay out the full text):
- `<= 500` chars: render in full.
- `> 500` chars: bounded preview + inline "Read more" that expands in place.
- `> 1500` chars: bounded preview + "Read more" that opens a dedicated full-message view.

Thresholds are tunable constants, sized from data (human-sent messages rarely exceed ~200 chars).

## "Read more" affordance
A distinct outline-pill button (1px `color/border/inverted/subtle`), not styled like message text -- clear touch target, visible in light and dark mode.

## Links
SwiftUI `Text` does not auto-detect links. Link-bearing bodies and the full-message view render via a UIKit text view with `dataDetectorTypes`. Link detection runs asynchronously (benchmarked cheap even for novel-length text), so it stays enabled for long/expanded messages and the detail view.

## Agent messages
Agents are prompted to keep messages short (~2 sentences). A deterministic backstop rejects outbound agent messages longer than 250 characters, prompting the agent to shorten the message or move the content to an attachment. As a result, agents should effectively never hit "Read more"; it is a human-only edge case (dictation / long typing). The agent-message limit is a separate workstream in the assistants/backend prompt.

## Future
Genuinely long content (e.g. paste) should use a text-attachment pattern (artifact-style) rather than a single large bubble. As that and the agent backstop land, "Read more" becomes a rare, human-only edge case.

## Cross-platform
Android should adopt the same display rules (thresholds, "Read more", dedicated view). Owner TBD; kept in sync.
