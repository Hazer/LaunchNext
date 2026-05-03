# LaunchNext Architecture Refactor — Master Plan

## Overview

A phased, incremental refactor of LaunchNext from its current monolithic architecture to a modern Swift concurrency/SOLID architecture. Each phase is independently reviewable, testable, and committable.

**Goals:**
- Compile-time thread safety via `actor`, `@MainActor`, `Sendable`
- Replace `DispatchQueue` with `async/await` and `Task`
- SOLID separation of concerns
- Each phase is well-documented enough for any AI or developer to pick up

**Target deployment:** macOS 26+ (Swift 6 concurrency features available)

**Pattern library consideration:** [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture) (TCA) — evaluate in Phase 2 whether to adopt it. It provides `@Reducer`, `@ObservableState`, `Effect`, and strict unidirectional data flow. If adopted, it would replace `ObservableObject` + `@Published` with TCA's `Store` pattern. **Decision deferred to Phase 2.**

---

## Phase 1: Concurrency Foundation

**Scope:** AppStore thread safety, async/await migration, AppScanner actor extraction.

**Risk:** Low — no structural changes, only internal implementation changes.

### 1.1 Add `@MainActor` to AppStore

**Problem:** AppStore has 85 `@Published` properties modified from multiple threads via `DispatchQueue.main.async` dispatches. There's no compile-time guarantee that mutations happen on the main thread.

**Changes:**
- Annotate `AppStore` with `@MainActor`
- This forces ALL methods to run on main actor by default
- Use `nonisolated` for methods that explicitly need to run off-main (scanning)
- Remove redundant `DispatchQueue.main.async` wrapping (the compiler enforces it now)

**Files:** `AppStore.swift`

### 1.2 Extract `AppScannerActor`

**Problem:** App scanning uses raw `DispatchQueue.global().async` with manual `NSLock` for thread safety. This is fragile and error-prone.

**Changes:**
- Create `AppScannerActor: Sendable` — encapsulates all disk scanning logic
- Internal state (discovered apps, seen paths) is actor-isolated (compile-time safe)
- Methods: `scanAll() async -> [AppInfo]`, `quickCheck() async -> Set<String>`, `checkChangedPaths(_ changed: Set<String>) async -> (inserted: [AppInfo], removed: [String])`
- Uses `TaskGroup` for concurrent directory enumeration (replaces manual `DispatchQueue(label:, attributes: .concurrent)`)
- Replace all scanning in AppStore with `await appScanner.scanAll()`

**New file:** `App/AppScannerActor.swift`
**Modified:** `AppStore.swift` (scanning methods become thin async wrappers)

### 1.3 Extract `FSEventsMonitorActor`

**Problem:** FSEvents callback runs on a custom `fsEventsQueue`, then dispatches to main. The C callback uses unsafe pointer casts. `pendingChangedAppPaths` and `pendingForceFullScan` are shared state modified from two threads without synchronization.

**Changes:**
- Create `FSEventsMonitorActor: Sendable`
- Actor-isolated `pendingChangedAppPaths` and `pendingForceFullScan`
- Wraps `FSEventStream` lifecycle, debounce timer, and change accumulation
- Exposes `func startMonitoring()`, `func stopMonitoring()`, `func changes() async -> Set<String>`
- AppStore creates and manages the actor; calls `let changes = await fsEventsMonitor.changes()` in a periodic Task

**New file:** `App/FSEventsMonitorActor.swift`
**Modified:** `AppStore.swift` (FSEvents code replaced with actor calls)

### 1.4 Replace DispatchQueue with async/await in AppStore

**Problem:** 25+ `DispatchQueue.main.async` and 6+ `DispatchQueue.global().async` calls in AppStore. With `@MainActor` on AppStore, these become redundant or need `nonisolated`.

**Changes:**
- Background scanning: already handled by AppScannerActor (1.2)
- `DispatchQueue.main.asyncAfter`: replace with `Task { try? await Task.sleep(for:) }`
- Debounce timers: create a lightweight `Debouncer` utility using `Task` + cancellation
- FSEvents debounce: already handled by FSEventsMonitorActor (1.3)
- `refreshQueue`: eliminated by actor extraction

**New file:** `Utilities/Debouncer.swift`
**Modified:** `AppStore.swift`

### 1.5 Replace Combine with `@Observable`

**Problem:** AppStore uses `ObservableObject` + 85 `@Published` properties with Combine `sink` chains. `@Observable` (macOS 14+, but we're on macOS 26) eliminates Combine boilerplate and enables fine-grained observation.

**Changes:**
- Change `class AppStore: ObservableObject` to `@Observable class AppStore`
- Remove `@Published` annotations (automatically tracked with `@Observable`)
- Remove `cancellables: Set<AnyCancellable>` and all `.sink` chains
- Replace with `withObservationTracking` or SwiftUI's native observation
- Keep search pipeline Combine usage temporarily — it involves debounce/throttle that's harder to replace without TCA

**Files:** `AppStore.swift`, all views that use `@ObservedObject var appStore: AppStore`

### Phase 1 Exit Criteria
- [ ] AppStore is `@MainActor`
- [ ] `AppScannerActor` handles all disk scanning
- [ ] `FSEventsMonitorActor` handles file system watching
- [ ] No `DispatchQueue.global().async` in AppStore
- [ ] AppStore uses `@Observable` instead of `ObservableObject`
- [ ] All tests pass, no regressions
- [ ] Architecture documentation updated

---

## Phase 2: Structure — Coordinator Pattern + View Model Extraction

**Scope:** Split AppDelegate, extract view models, split SettingsView.

**Risk:** Medium — structural changes but no behavior changes.

### 2.1 Split AppDelegate into Coordinators

**Problem:** AppDelegate is 1886 lines with 12+ responsibilities.

**Extract into:**

| Coordinator | Responsibility |
|------------|---------------|
| `WindowCoordinator` | Window creation, show/hide, animation, system UI |
| `HotKeyCoordinator` | Global hotkey registration/management |
| `GestureCoordinator` | Gesture monitor lifecycle + magnify suppressor |
| `CLICoordinator` | CLI endpoint monitoring, IPC server, command handling |
| `MenuBarCoordinator` | Status item creation and management |

AppDelegate becomes ~200 lines: app lifecycle + coordinator wiring.

**TCA evaluation:** Decide whether to adopt TCA here. If yes, coordinators become TCA features/reducers. If no, they remain plain classes.

**New files:** `Coordinators/WindowCoordinator.swift`, `Coordinators/HotKeyCoordinator.swift`, etc.
**Modified:** `LaunchpadApp.swift`

### 2.2 Extract View Models from LaunchpadView

**Problem:** LaunchpadView has 2000+ lines with view logic, drag state, pagination, and animation concerns mixed together.

**Extract into:**

| View Model | Responsibility |
|-----------|---------------|
| `LaunchpadViewModel` | `filteredItems`, `pages`, `currentItems`, `visualItems`, drag state, search |
| `DragDropViewModel` | Drag preview, pending drop index, external drag state |

LaunchpadView becomes a pure declarative view.

**New files:** `ViewModels/LaunchpadViewModel.swift`, `ViewModels/DragDropViewModel.swift`
**Modified:** `LaunchpadView.swift`

### 2.3 Split SettingsView

**Problem:** SettingsView is 5733 lines with 14 sections in one file.

**Extract each section into its own view:**

| View | Section |
|------|---------|
| `GeneralSettingsSection` | General settings |
| `AppearanceSettingsSection` | Icon size, colors, labels |
| `GridSettingsSection` | Columns, rows, spacing |
| `LayoutSettingsSection` | Layout mode, paged/vertical |
| `GestureSettingsSection` | Gesture configuration |
| `HotCornerSettingsSection` | Hot corner configuration |
| `SoundSettingsSection` | Sound effects |
| `ShortcutSettingsSection` | Keyboard shortcuts |
| `HiddenAppsSettingsSection` | Hidden apps management |
| `AppSourceSettingsSection` | Custom app sources |
| `BackupSettingsSection` | Import/export |
| `AboutSettingsSection` | App info, updates |

SettingsView becomes a container using `ScrollView` + `LazyVStack`.

**New files:** `Settings/*.swift` (12+ files)
**Modified:** `SettingsView.swift`

### Phase 2 Exit Criteria
- [ ] AppDelegate < 300 lines
- [ ] LaunchpadView < 500 lines
- [ ] SettingsView is a thin container
- [ ] All coordinators are testable in isolation
- [ ] Architecture documentation updated

---

## Phase 3: Full SOLID Refactor

**Scope:** Dependency injection, protocols, TCA evaluation, command patterns.

**Risk:** Higher — larger structural changes.

### 3.1 Protocol-Based Dependency Injection

**Problem:** Every view depends on concrete `AppStore`. `AppDelegate.shared` is accessed directly.

**Changes:**
- Define `AppStoreProtocol` with read-only properties that views need
- Views depend on `AppStoreProtocol` instead of `AppStore`
- Use environment-based injection for SwiftUI views
- Create `LaunchpadEnvironment` with all dependencies

### 3.2 TCA Adoption (or Decision to Stay Vanilla)

**Decision point:** Based on Phase 2 experience, decide:
- **Adopt TCA:** Migrate coordinators and view models to reducers + `Store`
- **Stay vanilla:** Keep `@Observable` + plain classes, just with better structure

### 3.3 Command Pattern for CLI

**Problem:** CLI command handler is a large `switch` statement (20+ cases).

**Changes:**
- `CLICommand` protocol with `execute() async -> CLIResult`
- `CLICommandRegistry` for registration
- Each command is its own struct conforming to `CLICommand`

### Phase 3 Exit Criteria
- [ ] Views depend on protocols, not concrete types
- [ ] CLI uses command pattern
- [ ] TCA decision made and implemented (or consciously deferred)
- [ ] Architecture documentation updated

---

## Phase 4: Polish and Review

**Scope:** Cleanup, final async/await migration in remaining files, documentation.

### 4.1 Migrate Remaining DispatchQueue Usage

Scan ALL Swift files and replace any remaining `DispatchQueue` with `Task`/`async`/`actor`.

### 4.2 Migrate Fallback Scan Timer to AsyncStream

The periodic fallback scan timer (`DispatchSourceTimer`) should use `Timer.publish` or `AsyncStream` + `Task.sleep`.

### 4.3 Static Mutable State Audit

Find and fix all `static var` mutable state (e.g., `LaunchpadView.geometryCache`).

### 4.4 Final Architecture Documentation

Update all architecture docs, add inline documentation for complex patterns.

### Phase 4 Exit Criteria
- [ ] Zero `DispatchQueue` usage in application code (C interop excepted)
- [ ] Zero unsynchronized shared mutable state
- [ ] Complete architecture documentation

---

## File Organization After Refactor

```
LaunchNext/
├── App/
│   ├── AppStore.swift              (slim coordinator, ~800 lines)
│   ├── AppScannerActor.swift      (new)
│   ├── FSEventsMonitorActor.swift  (new)
│   └── AppModels.swift             (existing models)
├── Coordinators/
│   ├── WindowCoordinator.swift     (new)
│   ├── HotKeyCoordinator.swift     (new)
│   ├── GestureCoordinator.swift    (new)
│   ├── CLICoordinator.swift       (new)
│   └── MenuBarCoordinator.swift   (new)
├── ViewModels/
│   ├── LaunchpadViewModel.swift    (new)
│   └── DragDropViewModel.swift    (new)
├── Views/
│   ├── LaunchpadView.swift        (slim, declarative)
│   ├── FolderView.swift
│   └── Settings/
│       ├── SettingsView.swift     (container)
│       ├── GeneralSettingsSection.swift
│       ├── AppearanceSettingsSection.swift
│       └── ...
├── Gesture/
│   ├── GestureMonitor.swift       (already modern ✅)
│   ├── MagnifyEventSuppressor.swift
│   ├── GestureStateMachine.swift
│   ├── GestureTouchProvider.swift
│   └── GestureConfiguration.swift
├── Grid/
│   ├── CAGridView.swift
│   ├── CAGridView+Layout.swift
│   ├── CAGridView+Input.swift
│   ├── CAGridViewRepresentable.swift
│   └── GridConfig.swift
├── Utilities/
│   ├── Debouncer.swift            (new)
│   ├── HotCornerMonitor.swift
│   └── SoundManager.swift
└── LaunchpadApp.swift             (thin AppDelegate, ~200 lines)
```
