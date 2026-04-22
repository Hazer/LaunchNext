# Phase 4: Polish and Review

**Status:** Not started
**Depends on:** Phase 3 complete

## Scope

Final cleanup: remaining DispatchQueue migration, static state audit, documentation.

**Risk:** Low — cleanup only.

---

## 4.1 Migrate Remaining DispatchQueue Usage

### Problem
Some files outside AppStore may still use `DispatchQueue` (e.g., CAGridView, FolderView, SettingsView debounce timers).

### Approach
- Scan ALL Swift files for `DispatchQueue` usage
- Replace with `Task`, `async/await`, or `actor` as appropriate
- Exception: C interop code (FSEvents callbacks, CVDisplayLink) can keep their queues

### Files
- All Swift files (grep-based scan)

---

## 4.2 Migrate Timers to Async Patterns

### Problem
`DispatchSourceTimer` for fallback scan and auto-update check could use modern async patterns.

### Approach
- Fallback scan: Already handled by `FSEventsMonitorActor` draining in Phase 1. Verify no `DispatchSourceTimer` remains.
- Auto-update check: Replace `DispatchSourceTimer` with `Task` + `Task.sleep` loop with proper cancellation.
- Settings debounce: Verify `Debouncer` utility (Phase 1.4) covers all debounce needs.

### Files
- `AppStore.swift` — verify timers migrated
- `SettingsView.swift` — verify debounce patterns

---

## 4.3 Static Mutable State Audit

### Problem
Static mutable state (e.g., `LaunchpadView.geometryCache`) is a thread-safety risk in SwiftUI (multiple view instances may access it concurrently).

### Approach
- Audit all `static var` mutable state in view files
- Move to appropriate location (view model, actor, or environment)
- If truly global, wrap in actor or `OSAllocatedUnfairLock`

### Files
- `LaunchpadView.swift` — `geometryCache`, `lastGeometryUpdate`

---

## 4.4 Final Architecture Documentation

### Approach
- Update `docs/00-master-plan.md` with final status
- Add inline documentation for:
  - Actor isolation boundaries
  - Main actor boundaries
  - Async call chains (where data flows async)
  - Testing strategy
- Create a concise `ARCHITECTURE.md` in the project root summarizing the final design

### Files
- **New:** `ARCHITECTURE.md` (project root)
- **Modified:** All doc files

---

## Phase 4 Exit Criteria
- [ ] Zero `DispatchQueue` usage in application code (C interop excepted)
- [ ] Zero unsynchronized shared mutable state
- [ ] `ARCHITECTURE.md` documents final design
- [ ] `docs/00-master-plan.md` shows all phases complete
