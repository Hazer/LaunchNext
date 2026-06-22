# Gesture system — handoff to next agent

**Created:** 2026-06-22
**Audience:** clean-context agent (Claude Code session) picking up the gesture work
**Scope:** finish the gesture system — take the scaffolded IOHIDTouchProvider to production, wire the state machine into the active detection path, and address the user-reported fullscreen-dismiss bug.

> Read this end-to-end before doing anything. Then read `docs/gesture-investigation.md` for the design context and history. The two docs are complementary: this one is task-focused (what to build), the other is reference (why it's designed this way).

---

## TL;DR

LaunchNext's gesture system (the 4-finger pinch that opens/closes the launcher) regressed when commit `9fe9d34` removed the OpenMultitouchSupport private-framework dependency. The replacement (`HIDGestureMonitor`) uses a public CGEventTap but only checks aggregate magnification — it lost the rich per-finger multi-criteria detection that the original OMS-based state machine did. Most of `GestureConfiguration`'s fields became dead code.

This session (2026-06-22) ported the lost `GestureStateMachine` (361 lines) to `LaunchNextInput/Gesture/` and scaffolded `IOHIDTouchProvider` (the public-API replacement for the OMS bridge). The state machine compiles and is ready to consume frames; the provider is a documented contract that needs implementation.

User reports a separate bug: the close gesture only dismisses the non-fullscreen window. That's likely a window-level / event-suppression interaction, not a detection issue — but it should be reproducible and fixed as part of this work.

## Current state (2026-06-22 end of session)

### What's on `develop` (builds clean)

- `LaunchNextInput/Gesture/GestureTypes.swift` — pure types (`GestureTouchSample {id: Int32, point: CGPoint}`, `GestureTouchFrame {deviceID: String, samples: [...]}`, `GestureTriggerAction {.open, .close, .toggle}`)
- `LaunchNextInput/Gesture/GestureStateMachine.swift` — 5-state per-finger detector, full multi-criteria triggers, tap detection. **Ported verbatim from `worktree-agent-afad21ec/LaunchNext/Gesture/GestureStateMachine.swift`**, only made `public`.
- `LaunchNextInput/Gesture/IOHIDTouchProvider.swift` — **SCAFFOLD**. Public surface compiles. `start()` returns false. `touchDataStream` yields nothing. Has an inline comment with the production contract.
- `LaunchNextInput/Gesture/HIDGestureMonitor.swift` — unchanged from main. Still the active detector. Still uses simple scale-ratio logic.
- `LaunchNextInput/Gesture/GestureMonitor.swift` — unchanged. Wraps HIDGestureMonitor.
- `LaunchNextInput/Gesture/GestureConfiguration.swift` — unchanged. Has all the fields (the OMS-removal kept the struct but the new detector ignores most of them).
- `Project.swift` — LaunchNextInput target now links `IOKit` framework.

### What is NOT done (the production work)

1. **`IOHIDTouchProvider.start()` and the report callback** — the load-bearing implementation. Read the inline contract in `IOHIDTouchProvider.swift` lines 95-160. Reference implementations: the `Multitouch` Mac app (github.com/MultitouchMac/Multitouch) and libOMS source.
2. **Wire `GestureStateMachine` into the active detection path.** Concretely: `GestureMonitor.swift` currently constructs a `HIDGestureMonitor` (the simple detector). It needs an alternate path that constructs an `IOHIDTouchProvider` + a per-device `[String: GestureStateMachine]` map. Switch between them via a configuration flag (so users can opt-in to the new detector for testing).
3. **Per-device routing logic** — when multiple trackpads are active, only one should drive gestures at a time. The OMS-era `GestureTouchProvider` had an `activeDeviceID` lock for this; the port should replicate it.
4. **The fullscreen-dismiss bug** — separate from detection, but in scope for this handoff. Reproduce first, then trace.

## Why the scaffold approach

Writing IOHIDManager correctly against Apple's multitouch HID records requires validating against real hardware, and the C-callback registration API has a 7-argument `@convention(c)` signature that can't capture `self` directly. Doing this blind (without runtime testing on actual trackpad hardware) would produce code that compiles but fails at runtime in subtle ways. Better to land the state machine design (which is sound and hardware-independent) plus a documented provider contract, then implement the provider with a tight test loop on real hardware.

## Implementation plan (in order)

### Step 1 — Validate HID reports on real hardware
Before writing parsing code, dump actual HID reports from a real trackpad:
- Create a scratch test (a small standalone Swift script, or a temporary `#if DEBUG` block in `IOHIDTouchProvider.start()`) that registers the input-report callback and logs the raw report bytes.
- Trigger 4-finger pinches on the trackpad. Capture the byte layout.
- Compare to the documented Apple multitouch HID record layout (see references below).

This is essential because Apple's HID multitouch report format is **not fully documented in the public IOHIDManager headers**. The layout has been reverse-engineered by the libOMS / Multitouch projects; without validating on your specific trackpad model, parsing code will be wrong.

### Step 2 — Implement `parseReport(_:length:)`
Once the byte layout is known, implement the parser in `IOHIDTouchProvider`:
- Walk the report's contact records
- For each: extract contact ID, X, Y, contact state (tip-switch / in-range / confidence)
- Filter to active-state contacts (mirror OMS's `.starting, .making, .touching, .breaking, .lingering` set)
- Build `[GestureTouchSample]`
- Determine `deviceID` from the IOHIDDevice's transport property, fallback to `IOHIDTouchProvider.unknownDeviceID`

### Step 3 — Fix the C-callback trampoline
`IOHIDManagerRegisterInputReportCallback` takes a `@convention(c)` closure that can't capture context. Standard pattern:
- Allocate an `Unmanaged<IOHIDTouchProvider>.passRetained(self)` opaque pointer
- Pass it as the `context` parameter to `IOHIDManagerRegisterInputReportCallback`
- Inside the static trampoline, recover the instance via `Unmanaged<IOHIDTouchProvider>.fromOpaque(context).takeUnretainedValue()`
- Dispatch into the instance method
- Release the unmanaged pointer in `stop()` / `deinit`

### Step 4 — Per-device routing
Maintain `[String: GestureStateMachine]` keyed by `deviceID`. When a frame arrives:
- Get-or-create the state machine for the frame's `deviceID`
- Apply "active device" routing: if a device is already active and the frame is from a different device, ignore (mirrors the OMS-era `GestureTouchProvider.route(_:)` logic)
- Feed the frame's samples to the active device's state machine via `consume(samples:at:)`
- Forward any emitted `GestureTriggerAction` to the `onTrigger` callback

### Step 5 — Wire into GestureMonitor
Modify `GestureMonitor.update(configuration:)` to switch between detectors based on a new config flag (e.g., `useEnhancedDetection: Bool`, default false):
- If `useEnhancedDetection` is true: use `IOHIDTouchProvider` + per-device `GestureStateMachine` map
- If false: use existing `HIDGestureMonitor` (preserve current behavior as default until the new path is validated)

### Step 6 — Address the fullscreen-dismiss bug
After the new detector works, reproduce the original bug:
- LaunchNext in fullscreen + hideMenuBar mode (so `window.level = mainMenu.rawValue + 1`)
- 4-finger pinch-out (close gesture)
- Expected: window hides. Reported: doesn't hide in fullscreen, only in windowed mode.

Hypotheses to check:
1. `updateWindowLevelForSystemUI` setting `window.level = mainMenuCarves + 1` interferes with system gesture routing
2. `isTracking` / `suppressFlag` in HIDGestureMonitor.handleEvent returns `nil` (suppress) at the wrong moment, blocking the system from delivering the close-pinch
3. `handleGestureTrigger`'s guards (lines 472-475 in LaunchpadApp.swift) reject the close action due to some fullscreen-specific state (`isAnimatingWindow`, `isPerformingExternalSystemDrag`, etc.)

The third hypothesis can be checked without fixing the detector — just add a log line in `handleGestureTrigger` and see if it fires for fullscreen.

## Acceptance criteria

The gesture work is done when:
- [ ] `IOHIDTouchProvider.start()` actually starts listening and yields real frames
- [ ] 4-finger pinch-in reliably opens LaunchNext (both fullscreen and windowed)
- [ ] 4-finger pinch-out reliably closes LaunchNext (both fullscreen and windowed) — **the original bug**
- [ ] Tap gesture (4-finger quick tap) toggles LaunchNext when `tapEnabled` is true
- [ ] False positives are reduced vs the current scale-ratio detector (validate informally — should not trigger on scrolling, normal trackpad use)
- [ ] `GestureConfiguration` fields that are currently vestigial (`openPerFingerRadiusRatio`, `closeLeadingFingerRadiusRatio`, etc.) are actually consumed by the detector
- [ ] Build clean (tuist generate + xcodebuild Debug)
- [ ] `worktree-agent-afad21ec` can be safely dropped (all needed reference code is on develop)

## Reference materials

### Files to read first
- `docs/gesture-investigation.md` — full design rationale, state-machine comparison, vestigial-config audit, three-path analysis
- `LaunchNextInput/Gesture/GestureStateMachine.swift` — the load-bearing logic, read it in full
- `LaunchNextInput/Gesture/IOHIDTouchProvider.swift` — current scaffold + inline contract
- `LaunchNextInput/Gesture/HIDGestureMonitor.swift` — current (regressed) detector
- `LaunchNextInput/Gesture/GestureMonitor.swift` — the wrapper that will switch between detectors
- `LaunchNext/LaunchpadApp.swift` lines 385-490 — where the gesture callback lands (`updateGestureMonitor`, `handleGestureTrigger`)
- `LaunchNext/LaunchpadApp.swift` line 1609+ — `hideWindow()` / `performHideWindow` flow (where the fullscreen bug may live)

### External references for IOHIDManager multitouch parsing
- **Multitouch Mac app**: `github.com/MultitouchMac/Multitouch` — public-API IOHIDManager-based multitouch reader. The `MultitouchDevice` and `MultitouchHelpers` classes show real HID parsing for Apple trackpads. This is the closest open-source reference.
- **libOMS / OpenMultitouchSupport**: the framework that was removed. Its source documents the private-multitouch-report layout. Even though we're not linking the private framework, the HID element structure it reverse-engineered is the same one IOHIDManager exposes via the public API.
- **Apple IOHIDManager docs**: `developer.apple.com/documentation/iokit/ihidmanager` — covers the API but not Apple-trackpad-specific layouts.
- **HID Usage Table Spec**: `usb.org/document-library/hid-usage-tables-122` — defines the digitizer usage page (0x000D) used for the device matching dictionary.

### Recovery sources (in case worktrees get dropped before this is done)
The state machine code is now on `develop` (this commit). The original OMS-era reference implementations are in:
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureStateMachine.swift` (the source we ported from)
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureTouchProvider.swift` (OMS bridge — the *input source* we're replacing with IOHIDTouchProvider)
- `worktree-agent-afad21ec/LaunchNext/Gesture/GestureMonitor.swift` (the per-device-map wrapper pattern, useful as a reference for Step 4)

**Tag these as archive refs before dropping afad21ec.** Suggested:
```bash
git tag archive/pre-gesture-port-2026-06-22/afad21ec-gesture worktree-agent-afad21ec
```

## Open questions for the agent (resolve at start)

1. Should the new detector replace `HIDGestureMonitor` entirely (one detector) or coexist (toggle between them)?
   - **Recommendation**: coexist initially via a config flag, default to old behavior. Switch default after validation.
2. Should `IOHIDTouchProvider` filter to built-in trackpad only by default, or accept all multitouch devices?
   - **Recommendation**: start with all devices, add filtering if multi-trackpad users complain about double-triggering.
3. The OMS-era `deviceSelectionMode` (`automatic` / `selected`) and `selectedDeviceIDs` config — bring them back?
   - **Recommendation**: defer. They were UI-driven and complicate the state machine wrapper. Add only if users actually need to disambiguate multiple trackpads.
4. Default config values: main's defaults (looser, more sensitive) or afad21ec's (stricter, fewer false positives)?
   - **Recommendation**: start with afad21ec's defaults since they were the result of actual tuning. Adjust based on testing.

## Non-goals (explicitly out of scope)

- Re-introducing the OpenMultitouchSupport private framework (it was removed for good reasons; this work uses only public APIs).
- Adding new gesture types beyond open/close/tap (e.g., swipes, rotates).
- Redesigning the `GestureConfiguration` struct (it's fine as-is; the fields just need to be wired).
- The Path B "undocumented CGEvent fields" investigation (skipped because Path A via IOHIDManager is more likely to yield the per-touch data).
- Tuning detection thresholds for every trackpad model (validate on what you have; document hardware-specific quirks as they emerge).
