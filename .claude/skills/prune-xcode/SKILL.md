---
name: prune-xcode
description: Reclaim Xcode and iOS-simulator disk space safely. Measures usage first, then clears the big recoverable caches (global DerivedData, per-worktree .derivedData while skipping any active build, module caches, old iOS DeviceSupport) and offers simulator cleanup (unavailable + duplicate + orphaned custom sims). Shows before/after free space; confirms destructive simulator/Archive deletions. Use when the user asks to free disk, prune DerivedData, clean Xcode/simulator storage, or "my disk is full".
---

# prune-xcode

Reclaim disk from Xcode / iOS build artifacts. Everything here EXCEPT simulator and Archive deletion is recoverable cache (it rebuilds), so the cache steps are safe to run unattended. Simulator/Archive deletion needs explicit confirmation (sims hold test state; Archives are submitted-build dSYMs/IPAs that don't rebuild).

## 0. Measure first (always)

Show the user where the space is BEFORE deleting anything:

```bash
df -h /System/Volumes/Data | tail -1
du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null
du -sh ~/Library/Developer/Xcode/iOS\ DeviceSupport 2>/dev/null
du -sh ~/Library/Developer/CoreSimulator/Devices 2>/dev/null
du -sh ~/Library/Developer/Xcode/Archives 2>/dev/null
du -sh ~/Library/Caches/com.apple.dt.Xcode 2>/dev/null
# per-worktree caches (repos that build with -derivedDataPath .derivedData):
find ~/dev -maxdepth 4 -name .derivedData -type d -exec du -sh {} \; 2>/dev/null
```

Present a table + the total reclaimable, then act.

## 1. DerivedData -- the usual monster (safe, recoverable)

Global DerivedData lives at `~/Library/Developer/Xcode/DerivedData`. It is pure build cache; Xcode rebuilds it on the next build. It is routinely 100s of GB.

- It has 100k+ files, so deleting it is SLOW -- ALWAYS run the delete in the background (run_in_background: true) or it times out and gets killed mid-sweep, leaving "Directory not empty" residue:
  ```bash
  rm -rf ~/Library/Developer/Xcode/DerivedData
  ```
- For a clean sweep the user should QUIT Xcode first -- an open Xcode keeps writing to DerivedData (you'll see "Directory not empty" if it recreates files mid-delete). If Xcode must stay open, just re-run the rm afterward; residual is harmless.

### Per-worktree .derivedData
Some repos build with `-derivedDataPath .derivedData` (a local cache per worktree). Delete the inactive ones, but SKIP any worktree with an active build:

```bash
pgrep -fl xcodebuild   # is a build running, and which derivedDataPath?
```
Skip the `.derivedData` of any path an active `xcodebuild` is using (or whose `.derivedData` was modified in the last few minutes). Delete the rest in the background:
```bash
rm -rf <worktree>/.derivedData
```

## 2. iOS DeviceSupport -- recoverable (re-extracted on device connect)

`~/Library/Developer/Xcode/iOS DeviceSupport/` holds per-iOS-version debug symbols for physical devices (several GB each). Keep the latest 1-2 OS versions, delete older:
```bash
ls -1 ~/Library/Developer/Xcode/iOS\ DeviceSupport/
rm -rf ~/Library/Developer/Xcode/iOS\ DeviceSupport/<old-version>
```
Reconnecting a device on a deleted version re-extracts it (slow but automatic). If unsure which to keep, ask.

## 3. Simulators -- CONFIRM before deleting (may hold test state)

```bash
xcrun simctl shutdown all 2>/dev/null
xcrun simctl delete unavailable        # safe: removes sims whose runtime you no longer have
```
For duplicate models / orphaned custom (per-task) sims:
- List: `xcrun simctl list devices`
- Identify duplicate models (keep one of each) + orphaned custom sims named after dead branches/tasks.
- CONFIRM the deletion list with the user, then delete each: `xcrun simctl delete <udid>`
- To reclaim a sim's DATA without deleting the device: `xcrun simctl erase <udid>`

## 4. Other caches (optional, smaller)

```bash
rm -rf ~/Library/Caches/com.apple.dt.Xcode      # safe
```
Do NOT delete `~/Library/Developer/Xcode/Archives` unless the user confirms -- those are submitted-build artifacts, not recoverable.

## 5. Report

Show `df -h /System/Volumes/Data` before vs after and the GB reclaimed.

## Safety rules
- Delete CACHE / build output only -- never source, worktrees, or `Archives` (without confirmation).
- Skip the `.derivedData` of any worktree with an active/in-flight build.
- Large deletes (DerivedData) MUST run in the background to avoid timeouts.
- Confirm before deleting simulators or DeviceSupport versions.
