# Test: Global Defaults Apply to New Conversation (Draft + Real)

Verify that Customize global defaults apply to a newly created draft conversation and remain correct after the conversation transitions to real status (when another member joins).

Run this test twice with two different setting combinations.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- Start from a clean state (Delete All Data) so no prior inbox/conversation state affects results.

## Test Matrix

Run the full scenario twice:

- **Run A**
  - Reveal mode / Blur incoming pics = ON
  - Include info with invites = ON
- **Run B**
  - Reveal mode / Blur incoming pics = OFF
  - Include info with invites = OFF

## Steps (execute for each run)

### 1) Configure global defaults

1. Open App Settings.
2. Open **Customize**.
3. Apply the values for the current run from the matrix above.
4. Return to the conversations list.

### 2) Validate defaults on new draft conversation

5. Tap compose to start a new conversation.
6. Open conversation info edit (Edit info).
7. Verify **Include info with invites** matches the run value.
8. Verify reveal preference matches the run value:
   - Blur ON run => auto-reveal OFF
   - Blur OFF run => auto-reveal ON

### 3) Transition draft -> real by having another member join

9. From the app, generate/copy an invite URL for this conversation.
10. Use CLI to join that invite with another participant.
11. Wait for the app conversation to transition from draft to real (joined member visible or ready state reflected in UI).

### 4) Validate defaults after real transition

12. Re-open conversation info edit.
13. Verify **Include info with invites** still matches the run value.
14. Verify reveal preference still matches the run value.

## Teardown

- Remove/explode created conversations (or run Delete All Data after both runs).

## Pass/Fail Criteria

- [ ] Run A draft values match global defaults
- [ ] Run A real-conversation values remain correct after member join
- [ ] Run B draft values match global defaults
- [ ] Run B real-conversation values remain correct after member join
- [ ] No unexpected reset to static/default values during either run
