# Your Space shell reference

Reference ID: `YS-SHELL-2026-08-18`

Status: pinned by the user for this prototype on August 18, 2026.

Source: user-attached image `codex-clipboard-3cc6e300-c7b1-40a2-9069-6480c38da797.png`, titled “Switching Spaces.” The attachment established shell topology, not product copy or data behavior.

## Pinned topology

```text
┌ profile ───── centered space switcher ───── add ┐
│                                                    │
│                private space content               │
│                                                    │
└ tools ───────────── primary context action ─────┘
```

- Top-left circular profile opens settings.
- The centered `Your Space` capsule opens every convo in a right-aligned panel anchored directly below the header. Your Space stays first, with search above the recency-sorted convo list; the home does not render a large chat list or use a bottom sheet for switching.
- Top-right circular add control offers exactly `Start a new convo` and `Join a convo` via QR.
- The bottom-left tools control opens widgets, connections, and the list of connected convos.
- Context is private until the user explicitly chooses what to share and which convo to open. The item is staged in that convo's composer for review and is never sent automatically.
- Contacts are reached inside invite and settings flows rather than through a persistent bottom tab.

## Intentional adaptation

The reference showed utility widgets as example private-space content. This implementation replaces those examples with a source-backed briefing and the “My context and connections” library: an editable personal card, cross-convo assets with provenance, search and type filters, local context creation, and an explicit share-to-composer handoff. The home screen's job is connected personal context rather than navigation.
