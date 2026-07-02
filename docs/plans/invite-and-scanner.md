# Invite + Scanner

Goal: make inviting friends/agents first-class, framed entirely as "added to your Contacts" (per the design walkthrough). Restore the removed in-app QR scanner and fold it into a Scan/Invite model. iOS only.

## Key finding: the scanner is not gone, just orphaned

The QR scanner was never deleted -- it compiles and is wired end-to-end. Its UI entry point was removed when the empty-state CTA was replaced (late May). Files present at HEAD: `QRScannerView`, `QRScannerViewModel`, `JoinConversationView`, `NewConversationView` (presents the scanner), `NewConversationViewModel` (`.scanner` mode + `handleScannedCode`). The surviving hook `ConversationsViewModel.onJoinConvo()` builds `mode: .scanner` but has zero callers. Restoring = attach a UI control to it. Restore risks are low: camera usage string present, no QR token-format drift, present via the existing `.sheet` (not `fullScreenCover`), agent-template QR already handled.

## Exists vs net-new

Exists: QR display (`QRCodeCardOverlay`), signed per-conversation invite links (`InviteWriter`, URL helper), share sheet, copy-link, in-conversation add-member (already splits contacts/agent/invite), make-agent (4 entries).

Net-new: the Scan/Invite segmented toggle, "Scan a screenshot" (camera-roll QR decode), the Contacts-view "top three" (Show code / Send invite / Make agent) -- make-agent is not launchable from Contacts today, a stylized QR generator (rounded modules + finder eyes + center logo), 2 design tokens (`radius extraLarge = 56`, `fillSubtle = #F5F5F5`).

## Stages

0. Foundations -- add the 2 `DesignConstants` tokens + the stylized QR generator.
1. Restore the scanner -- wire a Scan entry point to the orphaned `onJoinConvo()` (shared top bar). Brings the scanner back immediately.
2. Scan/Invite toggle -- add the Venmo-style segmented control to the QR-display screen (Scan tab = viewfinder, Invite tab = QR + share-link), restyled to Figma (floating nav, 280pt tile, captions). Two variants: inside an existing convo, and a fresh new convo.
3. Scan a screenshot -- camera-roll photo-picker -> QR decode.
4. The "+" picker -- generalize the new-convo picker sheet: top-three rows + searchable multi-select contacts list + Continue.
5. Contacts top-three -- same three actions on the Contacts view; "Send an invite" pops the share sheet directly; make-agent launchable from Contacts.
6. Wire-through -- "added to your Contacts" copy, post-scan results (join convo vs pull agent in), reconcile the two invite URL shapes.

## Open decisions (defaults proposed; confirm or override)

- Camera permission states (priming / denied): not in the 4 nodes. Default: reuse the scanner's existing permission handling + a standard priming/denied state.
- Post-scan result (join convo vs pull agent into current convo): logic exists in `handleScannedCode`; default to current behavior, restyled.
- Contacts-view variant of the top-three: not a separate node; default to mirroring the picker's top-three rows.
- Invite minting is always per-conversation (no standalone per-contact token) -- matches the "start a new convo, they're added to contacts" model. Keep that; no new invite primitive.
- Two invite URL shapes (`/v2?i=` generation vs `/i/` detector fallback): standardize on the generation shape, ensure the detector accepts both.

## Scope / sequencing

Likely a stacked set rather than one PR. Stage 1 (scanner restore) is shippable on its own. Base: `dev` (feature, not a 2.0.3 fix).
