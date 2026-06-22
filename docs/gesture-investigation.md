# Gesture system investigation

**Created:** 2026-06-22
**Trigger:** User pushback during consolidation session — Proposal E (GestureInputDevice) was prematurely dropped as "architecturally inapplicable." Deeper reading revealed main's gesture system is a significant regression from the worktree's design, and afad21ec's gesture stack should be preserved as a reference for a proper port.

## The current state of the gesture system

### Main (HIDGestureMonitor)
- **File**: `LaunchNextInput/Gesture/HIDGestureMonitor.swift` (public actor)
- **Wraps**: `GestureMonitor` (`LaunchNextInput/Gesture/GestureMonitor.swift`, `@MainActor` final class)
- **Input source**: single `CGEvent.tapCreate(tap: kCGHIDEventTap, ...)` — system-wide HID tap, fires for `kCGEventGesture` events of subtype "magnify"
- **Fields read from CGEvent**: `fingerCountField` (44), `phaseField` (51), `magnificationField` (61) — that's it
- **State model**: effectively 2-state (`isTracking` boolean). When finger count matches `requiredFingerCount` and phase is `began`, start tracking. On `changed`, smooth the magnification and compare `scaleRatio` to `openTriggerScaleRatio` (default 0.84) or `closeTriggerScaleRatio` (default 1.10). If exceeded for `minimumConsecutiveMatches` frames, fire `.open` or `.close`.
- **Tap detection**: NONE (the `tapEnabled` / `tapTogglesWindow` config exists but is dead code at the HID layer)
- **Per-finger tracking**: NONE
- **Centroid drift rejection**: NONE
- **Vestigial config**: most fields in `GestureConfiguration.swift` are set but never read by the detector: `openPerFingerRadiusRatio`, `closeLeadingFingerRadiusRatio`, `minimumOpenParticipatingFingerCount`, `minimumCloseLeadingGap`, `maximumCloseSupportingSpread`, `tapMaxDuration`, `tapMaxFingerMovement`, `tapMaxScaleDeviation`, `maximumCentroidDriftRatio`, `stableContactDuration`

### Worktree afad21ec (OMS-based, removed from main by commit `9fe9d34`)
- **Files**: `LaunchNext/Gesture/{GestureConfiguration,GestureInputDevice,GestureMonitor,GestureStateMachine,GestureTouchProvider}.swift`
- **Input source**: `OMSManager` (OpenMultitouchSupport private framework) via `GestureTouchProvider.touchDataStream: AsyncStream<GestureTouchFrame>`. Each frame: `{deviceID: String, samples: [GestureTouchSample]}` where `GestureTouchSample = {id: Int32, point: CGPoint}`. **Raw per-touch positions per device.**
- **Per-device state machines**: `GestureMonitor.start()` maintains `machines: [String: GestureStateMachine]` keyed by deviceID — separate state per trackpad, with "active device" routing (only the first device to report touches is active until it releases).
- **State model** (`GestureStateMachine`, 361 lines, 5 states):
  1. `idle` → waiting for `requiredFingerCount` touches
  2. `arming` → touches placed but not yet stable for `stableContactDuration`; collects baseline window
  3. `tracking` → stable baseline established; checks each frame against multi-criteria triggers
  4. `triggered` → fired; waits for fingers to lift
  5. `cooldown(until:)` → time-based suppression before re-arming
- **Open trigger** (multi-criteria AND):
  - `scaleRatio <= openTriggerScaleRatio` (default 0.84)
  - `centroidDrift <= maxDrift` (where `maxDrift = max(baselineScale * maximumCentroidDriftRatio, 0.04)`)
  - `inwardFingerCount >= minimumOpenParticipatingFingerCount` (fingers whose `currentRadius / baselineRadius <= openPerFingerRadiusRatio`)
- **Close trigger** (stricter multi-criteria AND):
  - `scaleRatio >= closeTriggerScaleRatio` (default 1.06 in worktree, 1.10 on main)
  - `centroidDrift <= maxDrift`
  - `leadingRatio >= closeLeadingFingerRadiusRatio` (default 1.12 — the most-outward finger's radial ratio)
  - `leadingGap >= minimumCloseLeadingGap` (default 0.06 — gap between leading finger and rest)
  - `supportingSpread <= maximumCloseSupportingSpread` (default 0.22 — non-leading fingers must be roughly together)
- **Tap detection** (separate path, fires on quick touch-and-release):
  - `tapEnabled` config (separate from pinch gestures)
  - Duration <= `tapMaxDuration` (0.20s)
  - Max finger movement <= `tapMaxFingerMovement` (0.045)
  - Max scale deviation <= `tapMaxScaleDeviation` (0.10)
  - Returns `.toggle` or `.open` based on `tapTogglesWindow`
- **Consecutive matches**: requires `requiredConsecutiveMatches` (default 2) consecutive frames meeting all criteria before firing — prevents micro-jitter false positives
- **Smoothing**: exponential moving average with `smoothingAlpha = 0.7` on scale

### Why main regressed
Commit `9fe9d34` (2026-04-21) removed OMS to eliminate the private-framework dependency. The replacement `HIDGestureMonitor` uses the public `CGEventTap` API — but `kCGEventGesture` events only expose aggregate metrics (magnification delta, rotation, phase, finger count), **not per-touch positions**. So the entire `GestureStateMachine` couldn't be ported as-is; it was replaced with the simple scale-ratio detector. The `GestureConfiguration` struct kept all the per-finger / tap fields (presumably hoping they'd be re-wired later) but the new detector ignores them.

## Why this matters (user-reported bug)

User reports: *"the gesture should be system wide, it is the gesture to show the launchnext itself against everything... also be able to dismiss the full screen launchnext with the gesture, for some reason, it only dismisses the version that isn't full screen."*

The system-wide detection IS correct (CGEventTap at HID level). The fullscreen-dismiss bug is in a different layer — likely:
1. Window-level interaction: in fullscreen + hideMenuBar mode, `window.level = NSWindow.Level.mainMenu.rawValue + 1`. Windows above the main-menu level can interfere with system gesture routing on some macOS versions.
2. Or the magnify-event suppression (`return isTracking ? nil : ...` in `handleEvent`) backfires when the system has a different view of who should receive the event in fullscreen.

But the deeper issue is **fidelity**: main's detector is so simple it's prone to false positives (any 4-finger pinch triggers) and can't distinguish "show LaunchNext" from "I'm just scrolling." The worktree's state machine was designed specifically to fix this — multi-criteria triggers with arming phase + drift rejection. Main lost all that.

## Three paths forward

### Path A: Port state machine to IOHIDManager (public API)
- **Approach**: use `IOHIDManagerCreate` with the multitouch HID record matching dictionary. Apple trackpads expose per-finger records via HID. Apps like BetterTouchTool and Multitouch use this approach.
- **Pros**: gets back the per-touch data that `GestureStateMachine` needs. State machine ports almost verbatim (just swap `OMSTouchFrame` → HID record struct). Public API (no private framework).
- **Cons**: lower-level than CGEventTap; needs HID descriptor parsing. Performance/battery considerations (always listening to HID events). Requires entitlements / may need user permission on newer macOS. Behavior may differ between trackpad models.
- **Effort**: ~1-2 days of careful work + testing.

### Path B: Enumerate undocumented kCGEventGesture fields
- **Approach**: dump every `CGEventField` raw value on a `kCGEventGesture` event and see if any expose per-touch data. The fields main reads (44, 51, 59, 61) are documented in `HIDGestureMonitor.swift` as "not exposed as named constants in Swift SDK" — there may be more undocumented fields.
- **Pros**: stays on the existing CGEventTap architecture; no new entitlements.
- **Cons**: relies on undocumented behavior. May not exist. Brittle across macOS versions.
- **Effort**: a few hours of investigative work; if fields exist, ~1 day to wire up; if not, fall back to Path A or C.

### Path C: Hybrid (CGEventTap trigger + IOHIDManager sampling)
- **Approach**: keep CGEventTap as the always-on cheap trigger (fires on every magnify event). When `fingerCount == requiredFingerCount`, spin up IOHIDManager briefly to capture per-touch positions for the duration of the gesture. When the gesture ends (fingers lift or finger count changes), shut down IOHIDManager.
- **Pros**: best of both — cheap when idle, full data when gesture in progress.
- **Cons**: most complex to implement. State coordination between the two input paths.
- **Effort**: ~2-3 days.

## Recommendation

**Start with Path B (enumerate undocumented fields).** It's the cheapest investigation. If `kCGEventGesture` events expose per-touch data via some field we haven't read, the port is straightforward and stays on the current architecture. If not, fall back to Path A (IOHIDManager).

Independent of which path: the goal is to **bring `GestureStateMachine.swift` back from afad21ec and wire it as the detector**, replacing main's simple scale-ratio logic. The state machine itself is sound; only its input source needs to change.

## Recovery / reference sources

The worktree's gesture stack is preserved in:
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureConfiguration.swift` (26 lines, config struct)
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureInputDevice.swift` (20 lines, device-selection abstractions — may not be needed in the port, depends on whether IOHIDManager exposes device selection)
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureMonitor.swift` (76 lines, top-level wrapper — needs full rewrite for new input source)
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureStateMachine.swift` (361 lines, **THE LOAD-BEARING FILE** — ports almost as-is)
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureTouchProvider.swift` (133 lines, OMS bridge — **REPLACES with new input source**)

**afad21ec must be preserved as a reference worktree until the gesture port lands.** It is NOT safe to drop after consolidation; the gesture stack is the source of truth for the design we want to bring back.

## Open questions

1. Does `kCGEventGesture` expose per-touch positions via undocumented fields? (Need to instrument and dump.)
2. If not, is IOHIDManager viable for system-wide trackpad multitouch? (Needs proof-of-concept.)
3. The fullscreen-dismiss bug — separate issue from the detector regression, or related? (Need runtime repro to confirm.)
4. Should the gesture system be opt-in (off by default, like current `gestureEnabled` default) or always-on? (UX/policy decision.)
