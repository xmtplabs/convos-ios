# IOS-236 — QA checklist (E2E)

## What is a QA checklist format?

A QA checklist is a test plan written as actionable, repeatable test cases with clear pass/fail outcomes.

Typical format:
- **ID** (e.g. `TC-01`)
- **Preconditions**
- **Steps**
- **Expected result**
- **Status** (`[ ] Pass / [ ] Fail`) and optional notes

## Existing examples in this repo

- `docs/plans/2025-01-24-image-cache-encryption-integration.md` → "Verification Checklist"
- `docs/plans/2026-01-22-background-photo-upload.md` → "Testing Checklist"

This file follows the same spirit, but with explicit test case IDs for easier execution tracking.

---

## Scope

Validate IOS-236 end-to-end:
- Global defaults UI and persistence
- New conversation seeding (creation path)
- No retroactive changes to existing convos
- Reveal onboarding gating
- Image send/receive behavior in new convo
- Include-info-with-invites behavior
- Reset behavior

## Environments / actors

- App build: `Convos (Dev)`
- Primary device: simulator `convos-global-reveal`
- Secondary device/account for join + media flows
- Network available

## Global execution notes

- Record status per case: `[ ] Pass` / `[ ] Fail`
- Capture screenshots for UI and key state transitions
- If a case fails, include short repro notes + observed vs expected

---

## Test cases

### TC-01 — Customize entry in App Settings
**Preconditions**: App launched, logged into a usable test state.  
**Steps**:
1. Open App Settings.
2. Locate the row leading to customize defaults.
3. Check if old Notifications placeholder row is present.

**Expected**:
- A row for **Customize** is present and opens settings.
- Notifications placeholder row is not present.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-02 — Customize screen copy and structure
**Preconditions**: On Customize screen.  
**Steps**:
1. Verify page title.
2. Verify section header.
3. Verify rows and subtitles.

**Expected**:
- Title: **Customize**
- Header: **Your new convos**
- Row 1: Reveal mode / Blur incoming pics
- Row 2: Include info with invites / When enabled, anyone with your convo code can see its pic, name and description
- Row 3: Colors with Soon state

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-03 — Global default values (fresh/reset state)
**Preconditions**: Fresh install or state reset.  
**Steps**:
1. Open Customize screen after reset.
2. Read toggle values.

**Expected**:
- Reveal mode default: **ON**
- Include info with invites default: **OFF**

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-04 — Toggle persistence across navigation/relaunch
**Preconditions**: On Customize screen.  
**Steps**:
1. Toggle both controls to opposite values.
2. Navigate back and return to Customize.
3. Kill and relaunch app.
4. Re-open Customize.

**Expected**:
- Toggle values persist after navigation and app relaunch.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-05 — New convo seeded from global defaults (variant A)
**Preconditions**:
- Set globals: Reveal **ON**, Include info **OFF**.

**Steps**:
1. Create a brand new conversation (creation path).
2. Open convo settings.
3. Check effective Reveal behavior and Include info setting.

**Expected**:
- New convo starts with reveal behavior corresponding to global Reveal ON.
- Include info with invites starts OFF for this new convo.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-06 — New convo seeded from global defaults (variant B)
**Preconditions**:
- Set globals: Reveal **OFF**, Include info **ON**.

**Steps**:
1. Create another brand new conversation (creation path).
2. Open convo settings.
3. Check effective Reveal behavior and Include info setting.

**Expected**:
- New convo starts with reveal behavior corresponding to global Reveal OFF.
- Include info with invites starts ON for this new convo.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-07 — Existing convo unaffected by later global changes
**Preconditions**:
- At least one existing convo created under prior defaults.

**Steps**:
1. Change global defaults to opposite values.
2. Reopen existing convo(s).
3. Check per-convo reveal/include-info behavior/settings.

**Expected**:
- Existing convo behavior/settings remain unchanged.
- Global changes do not retroactively override previous convo values.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-08 — Reveal onboarding visible when global Reveal ON
**Preconditions**:
- Global Reveal ON.
- New convo created.
- Second participant available to send image.

**Steps**:
1. Receive first image in the new convo.
2. Reveal/interact with image.

**Expected**:
- Reveal onboarding/info-sheet/toast behavior appears (IOS-314 behavior retained).

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-09 — Reveal onboarding suppressed when global Reveal OFF
**Preconditions**:
- Global Reveal OFF.
- New convo created.
- Second participant sends image.

**Steps**:
1. Receive first image in new convo.
2. Interact with image.

**Expected**:
- Reveal onboarding/info-sheet/toast is suppressed.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-10 — Image receive behavior when reveal mode ON
**Preconditions**:
- New convo seeded with reveal ON behavior.
- Second participant can send image.

**Steps**:
1. Receive image.
2. Observe initial rendering.
3. Perform reveal action.

**Expected**:
- Image starts blurred.
- Reveal action unblurs successfully.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-11 — Image receive behavior when reveal mode OFF
**Preconditions**:
- New convo seeded with reveal OFF behavior.
- Second participant can send image.

**Steps**:
1. Receive image.
2. Observe initial rendering.

**Expected**:
- Image is shown without reveal-gated blur.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-12 — Per-convo override wins after creation
**Preconditions**:
- New convo created from globals.

**Steps**:
1. Change per-convo Reveal mode toggle.
2. Send/receive another image.

**Expected**:
- Behavior follows per-convo toggle, not global default.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-13 — Include-info OFF invite preview behavior
**Preconditions**:
- Convo with include-info OFF.
- Invite/join flow available on second account.

**Steps**:
1. Share invite.
2. Open invite pre-join experience on second account.

**Expected**:
- Pic/name/description are not exposed in pre-join preview.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-14 — Include-info ON invite preview behavior
**Preconditions**:
- Convo with include-info ON.
- Invite/join flow available on second account.

**Steps**:
1. Share invite.
2. Open invite pre-join experience on second account.

**Expected**:
- Pic/name/description are visible in pre-join preview.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-15 — Delete all app data resets globals
**Preconditions**:
- Set non-default global toggle values.

**Steps**:
1. Run Delete all app data.
2. Reopen app and navigate to Customize.

**Expected**:
- Reveal mode reset to ON.
- Include info with invites reset to OFF.

Status: [ ] Pass [ ] Fail  
Notes:

---

### TC-16 — Debug reset resets globals (optional but recommended)
**Preconditions**:
- Debug menu accessible.
- Set non-default global toggle values.

**Steps**:
1. Trigger debug reset-all-settings.
2. Reopen Customize.

**Expected**:
- Global defaults are reset.

Status: [ ] Pass [ ] Fail  
Notes:

---

## Final sign-off summary

- [ ] All critical cases passed (`TC-01` to `TC-15`)
- [ ] Screenshots attached for key flows
- [ ] No regressions observed in IOS-314 reveal behavior
- [ ] Ready for merge / further QA
