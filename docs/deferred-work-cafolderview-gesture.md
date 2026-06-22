# Deferred work — CAFolderGridView + GestureInputDevice integration

**Created:** 2026-06-21 (during consolidation Phase E)
**Status:** Deferred from consolidation pass. Tracked here for a future session.
**Build state at deferral:** develop branch builds clean (BUILD SUCCEEDED) without these.

## Why deferred

Proposals C (CAFolderGridView) and E (GestureInputDevice) were deferred during the 2026-06-21 consolidation because the salvaged files target an **older architecture** that current `main`/`develop` has moved past. Two specific refactor epochs intervened:

1. **SettingsStore extraction** (commit `5b14d92`, Phase 2 manager-extraction work, 2026-05-03) — moved ~76 `@Published` settings properties off `AppStore` into a new `SettingsStore` class.
2. **OMS removal** (commit `9fe9d34`, IMPROVEMENT_PLAN Priority 1) — removed `ThirdParty/OpenMultitouchSupportXCF/` entirely and replaced it with `LaunchNextInput/HIDGestureMonitor` (CGEventTap-based).

Both deferred assets were written **before** these refactors and reference types/properties that no longer exist (or have moved).

## Proposal C — CAFolderGridView integration

### Source files (in worktrees, byte-identical between the two)
- `LaunchNext/CAFolderGridView.swift` (1,345 lines) — Core Animation NSView for folder content grid
- `LaunchNext/CAFolderGridViewRepresentable.swift` (133 lines) — NSViewRepresentable bridge to SwiftUI

**Available in:** `worktree-agent-af967f48` and `worktree-agent-afad21ec` (MD5-verified identical).

### What it does
A Core Animation–backed renderer for the folder-open view, parallel in role to how `CAGridView` is the CA renderer for the main grid. Supports both paged and vertical-scroll layouts, hover magnification, active-press effect, batch selection, drag reordering. Currently main uses SwiftUI `FolderView` (`LaunchNext/FolderView.swift`, 739 lines) for the same job.

### Why it doesn't compile against current develop

**Reference audit performed (2026-06-21):**

`CAFolderGridViewRepresentable.swift` calls **23** `appStore.X` properties/methods:

| Status | Count | Symbols |
|---|---|---|
| Work as-is (on AppStore) | 7 | `handoffDragScreenLocation`, `handoffDraggingApp`, `hideApp`, `localized`, `openConfiguredUninstallTool`, `removeAppFromFolder`, `uninstallToolAppURL` |
| Need rewrite to `appStore.settingsStore.X` | 12 | `activePressScale`, `animationDuration`, `enableActivePressEffect`, `enableAnimations`, `enableHoverMagnification`, `hoverMagnificationScale`, `iconLabelFontSize`, `iconLabelFontWeight`, `isLayoutLocked`, `reverseWheelPagingDirection`, `scrollSensitivity`, `showLabels` |
| **Missing entirely on main** | 4 | `copyAppPath`, `showAppInFinder`, `reorderAppInFolder`, `folderLayoutMode` |

`CAFolderGridView.swift` itself references:
- `AppStore.FolderLayoutMode` (nested enum) — **doesn't exist on main**
- `AppStore.defaultScrollSensitivity` — moved to `SettingsStore.defaultScrollSensitivity`

### Integration plan

1. **Add missing symbols to current architecture:**
   - Add `FolderLayoutMode` enum (cases: `paged`, `vertical`) to **`SettingsStore.swift`** (not nested in AppStore — follow the post-extraction pattern).
   - Add `folderLayoutMode: FolderLayoutMode` `@Published` property to SettingsStore with UserDefaults backing (mirror the `layoutMode` pattern already there).
   - Decide where `copyAppPath(_:)`, `showAppInFinder(_:)`, `reorderAppInFolder(_:from:to:)` belong. Likely candidates:
     - `copyAppPath` and `showAppInFinder` are simple NSWorkspace wrappers — could go on `AppStore` (since they're actions, not state) OR on individual `ContextMenuAction` types (cleaner architecturally — the ContextMenu registry already has `ShowInFinderAction` which is the better home).
     - `reorderAppInFolder` belongs on `FolderManager` (the extracted manager that owns folder mutations).
   - Look at how main's existing `FolderView` calls equivalent operations — port that pattern.

2. **Rewrite `CAFolderGridViewRepresentable.swift` to use `appStore.settingsStore.X`** for the 12 moved properties. Mechanical find/replace, but verify each call site.

3. **Rewrite `CAFolderGridView.swift`** references:
   - `AppStore.FolderLayoutMode` → `SettingsStore.FolderLayoutMode` (or wherever the enum lands)
   - `AppStore.defaultScrollSensitivity` → `SettingsStore.defaultScrollSensitivity`

4. **Wire it into `LaunchpadView`** as an alternative to the SwiftUI `FolderView` at line 707. Either:
   - Replace `FolderView(...)` with `CAFolderGridViewRepresentable(...)` unconditionally, OR
   - Add a setting (e.g., `useCAGridRendererForFolders` — main already has `useCAGridRenderer` for the main grid) and switch on it.

5. **Verify build + manual test** — folder open/close, scroll, drag-reorder, context menu, hover magnification.

### Estimated effort
~3–5 hours of careful work for someone who knows the codebase. The bulk is the 12-path settings rewrite + designing where the 4 missing symbols land. The NSView itself is unchanged.

## Proposal E — GestureInputDevice integration

### Source file
- `LaunchNext/Gesture/GestureInputDevice.swift` (20 lines)

**Available in:** `worktree-agent-af967f48` only.

### What it does
Defines `GestureDeviceSelectionMode` enum (`automatic` / `selected`) and `GestureInputDevice` struct (id, name, isBuiltIn). Adds a computed `isGestureTrackpadCandidate` property on `OMSDeviceInfo`.

### Why it doesn't compile against current develop

The file extends `OMSDeviceInfo`, which was part of `ThirdParty/OpenMultitouchSupportXCF/` — **removed from main** by commit `9fe9d34` (OMS → HIDGestureMonitor migration). Extending a type that doesn't exist = compile error.

### Integration plan

1. **Decide if this abstraction is still needed.** Main replaced OMS with `HIDGestureMonitor` (CGEventTap). The concept of "select which input device feeds gestures" may or may not translate cleanly to the new architecture. Check `HIDGestureMonitor.swift` for whether device selection is even possible there (CGEventTap is system-wide; OMS was per-device).

2. **If still needed:**
   - Drop the `OMSDeviceInfo` extension entirely (3 lines).
   - Keep `GestureDeviceSelectionMode` and `GestureInputDevice` (17 lines) — they're framework-agnostic.
   - Find where the worktree *used* these (likely `GestureConfiguration.swift`, `GestureMonitor.swift`, `LaunchpadApp.swift` gesture binder, `SettingsView.swift` device picker UI) — those call sites need porting too, since they were OMS-specific.
   - This effectively becomes "port the configurable-device-selection feature to HIDGestureMonitor" — non-trivial, may require new IOHIDManager queries to enumerate candidate devices.

3. **If not needed:** drop the proposal. The OMS removal was intentional; gesture device selection was tied to OMS's per-device API. Document the decision.

### Estimated effort
~2–4 hours if porting to HIDGestureMonitor (depends on whether CGEventTap / IOHIDManager exposes equivalent device enumeration). 0 if deciding to drop.

## Recovery sources (if worktrees get archived/dropped before this lands)

Both deferred assets are reachable from these refs as of 2026-06-21:

| Asset | Reachable from |
|---|---|
| `LaunchNext/CAFolderGridView.swift` (1,345 lines, blob `f8bcd9b3a298`) | `worktree-agent-af967f48`, `worktree-agent-afad21ec` |
| `LaunchNext/CAFolderGridViewRepresentable.swift` (133 lines, blob `374d7eaed106`) | same |
| `LaunchNext/Gesture/GestureInputDevice.swift` (20 lines, blob `6e80bb68bae9`) | `worktree-agent-af967f48` only |

**Recommended before any worktree deletion (Phase F):**
1. Create archive tags: `archive/pre-consolidation-2026-06-21/af967f48-unique-assets` and `archive/pre-consolidation-2026-06-21/afad21ec-unique-assets`.
2. Or: copy the 5 source files (`CAFolderGridView.swift`, `CAFolderGridViewRepresentable.swift`, `GestureInputDevice.swift` + the relevant Gesture/* / SettingsView.swift sections from the worktrees) into `docs/deferred-assets/` for offline reference.

This way, even if all worktrees are removed, the source is recoverable without reflog archaeology.

## Open design questions for the next session

1. **Does the project actually want CAFolderGridView?** Main's SwiftUI `FolderView` works. CAFolderGridView is a performance-oriented alternative (CA renders faster than SwiftUI for large grids). Is the perf difference measurable for typical folder sizes (< 50 apps)?
2. **If yes, where does `FolderLayoutMode` live?** SettingsStore is the natural home per current architecture, but the v2 spec put layout strategies in `LaunchNextStrategies/` framework target. Reconcile.
3. **Where do `copyAppPath` / `showAppInFinder` / `reorderAppInFolder` live?** ContextMenu action types vs AppStore vs FolderManager — architectural call.
4. **Is gesture device selection still relevant post-OMS-removal?** Probably depends on whether users have multi-trackpad setups that need disambiguation.

## Done criteria

This doc can be deleted/archived when:
- [ ] CAFolderGridView either lands on develop (builds clean, wired to FolderView replacement) OR is explicitly rejected with rationale
- [ ] GestureInputDevice either ports to HIDGestureMonitor OR is explicitly rejected with rationale
- [ ] All decisions captured in the post-consolidation handoff doc
