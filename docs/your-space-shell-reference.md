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
- The centered `Your Space` capsule opens every convo as a switcher; the home does not render a large chat list.
- Top-right circular add control offers exactly `Start a new convo` and `Join a convo` via QR.
- The bottom-left tools control opens widgets, connections, and the list of connected convos.
- Context is private until the user explicitly chooses what to copy and which convo to open.
- Contacts are reached inside invite and settings flows rather than through a persistent bottom tab.

## Intentional adaptation

The reference showed utility widgets as example private-space content. This implementation replaces those examples with a source-backed briefing, attention queue, cross-convo updates, people pulse, and optional footprint widget because the user explicitly changed the home screen's job from navigation to connected personal context.
