# Phase 1: Concurrency Foundation

**Status:** Not started
**Depends on:** Master plan

## Scope

AppStore thread safety, async/await migration, AppScanner actor extraction, FSEvents monitor actor extraction, @Observable migration, Debouncer utility.

**Risk:** Low — no structural changes to the view hierarchy or public API. Only internal AppStore implementation changes and new extracted types.

---

## 1.1 Add `@MainActor` to AppStore

### Problem
AppStore has 85 `@Published` properties modified from multiple threads via `DispatchQueue.main.async` dispatches. There's no compile-time guarantee that mutations happen on the main thread.

### Approach
- Add `@MainActor` to `class AppStore`
- All methods become main-actor-isolated by default
- Mark scanning and FSEvents methods with `nonisolated` where they need to run off-main
- Remove redundant `DispatchQueue.main.async` wrapping — the compiler now enforces main-thread access
- Any accidental background thread access to AppStore properties becomes a compile error

### Files
- `AppStore.swift` — add annotation, remove redundant dispatch wrappers

### Testing
- Build should still succeed (no behavior change)
- Verify no warnings from Sendable conformance issues
- Manually test: app scanning, FSEvents, search, settings changes all still work

---

## 1.2 Extract `AppScannerActor`

### Problem
App scanning uses raw `DispatchQueue.global().async` with manual `NSLock` for thread safety. The `scanApplicationsWithOrderPreservation()` method creates a `DispatchQueue(label: "app.scan", attributes: .concurrent)` with manual `lock.lock()/lock.unlock()` — fragile and error-prone.

### Approach
Create a new actor that encapsulates all disk scanning logic:

```swift
actor AppScannerActor {
    func scanAll() async -> [AppInfo]
    func quickCheck() async -> Set<String>
    func checkChangedPaths(_ changed: Set<String>) async -> (inserted: [AppInfo], removed: [String])
}
```

- `scanAll()`: Uses `TaskGroup` for concurrent directory enumeration (replaces manual concurrent `DispatchQueue` + `NSLock`)
- `quickCheck()`: Lightweight path-only scan for startup soft-refresh and fallback check
- `checkChangedPaths()`: For FSEvents incremental updates
- AppStore's scanning methods become thin `async` wrappers that `await` the actor

### Files
- **New:** `App/AppScannerActor.swift`
- **Modified:** `AppStore.swift` — scanning methods delegate to actor

### Testing
- Unit test `AppScannerActor` in isolation (mock file system or real paths)
- Verify scan results match current behavior (same apps found, same order)
- Test concurrent access safety (multiple callers should not crash)

---

## 1.3 Extract `FSEventsMonitorActor`

### Problem
FSEvents callback runs on `fsEventsQueue`, then dispatches accumulated changes to main via `DispatchQueue.main.async`. `pendingChangedAppPaths` (a `Set<String>`) and `pendingForceFullScan` (a `Bool`) are shared mutable state modified from both `fsEventsQueue` (in `handleFSEvents`) and main thread (in `performImmediateRefresh`) without any synchronization.

### Approach
Create a new actor that wraps the entire FSEvents lifecycle:

```swift
actor FSEventsMonitorActor {
    private var pendingChangedAppPaths: Set<String> = []
    private var pendingForceFullScan: Bool = false

    func startMonitoring(paths: [String]) async
    func stopMonitoring()
    func drainChanges() -> (changedPaths: Set<String>, forceFullScan: Bool)
}
```

- Actor isolation makes `pendingChangedAppPaths` and `pendingForceFullScan` thread-safe by default
- The C callback (`handleFSEvents`) still fires on `fsEventsQueue`, but only writes to actor-isolated state (safe via `await self.method()` from an async context)
- Debounce timer uses `Task.sleep` inside the actor instead of `DispatchWorkItem`
- AppStore polls `drainChanges()` in a periodic `Task` (replaces the `DispatchSourceTimer` fallback scan timer)

### Files
- **New:** `App/FSEventsMonitorActor.swift`
- **Modified:** `AppStore.swift` — FSEvents setup/teardown delegates to actor

### Testing
- Test that FSEvents changes are properly accumulated and drained
- Test debounce behavior (rapid changes are coalesced)
- Test stop/start lifecycle

---

## 1.4 Replace DispatchQueue with async/await in AppStore

### Problem
25+ `DispatchQueue.main.async` and 6+ `DispatchQueue.global().async` calls in AppStore. Many are redundant once `@MainActor` is applied.

### Approach
- Background scanning: already handled by `AppScannerActor` (1.2) and `FSEventsMonitorActor` (1.3)
- `DispatchQueue.main.asyncAfter(deadline:)` → `Task { try? await Task.sleep(for:) }` with proper cancellation
- Debounce timers: create `Debouncer` utility (see below)
- `DispatchSourceTimer` (fallback scan, auto-update check) → `Task` + `Task.sleep` loop with cancellation
- `DispatchQueue.main.async` → remove entirely (compiler enforces via `@MainActor`)

### Debouncer Utility

```swift
final class Debouncer: Sendable {
    func schedule(action: @escaping @Sendable () async -> Void)
    func cancel()
}
```

### Files
- **New:** `Utilities/Debouncer.swift`
- **Modified:** `AppStore.swift` — replace all remaining DispatchQueue usage

### Testing
- Verify debounce timing matches previous behavior
- Test cancellation (rapid successive operations should only trigger once)

---

## 1.5 Replace Combine with `@Observable`

### Problem
AppStore uses `ObservableObject` + 85 `@Published` properties with Combine `sink` chains. `@Observable` (available since macOS 14, confirmed available on macOS 26) eliminates Combine boilerplate and enables fine-grained observation — views only re-render when the specific properties they read actually change.

### Approach
- Change `class AppStore: ObservableObject` to `@Observable class AppStore`
- Remove all `@Published` annotations — `@Observable` tracks access automatically
- Remove `cancellables: Set<AnyCancellable>` and all `.sink { }` chains
- Views using `@ObservedObject var appStore: AppStore` continue to work (SwiftUI observation bridge)
- **Exception:** Keep the search pipeline Combine chain temporarily — it uses `.debounce(for:scheduler:)` and `.removeDuplicates()` which have no direct `@Observable` equivalent. This will be addressed in Phase 2 or 3.

### Files
- **Modified:** `AppStore.swift` — class annotation, remove @Published and sink
- **Modified:** All view files — verify `@ObservedObject` still works with `@Observable`

### Testing
- Build succeeds with no warnings
- Manual test: all UI updates still trigger correctly
- Verify search pipeline still works (it still uses Combine internally)

---

## Phase 1 Exit Criteria
- [ ] AppStore is annotated with `@MainActor`
- [ ] `AppScannerActor` handles all disk scanning
- [ ] `FSEventsMonitorActor` handles file system watching
- [ ] No `DispatchQueue.global().async` remaining in AppStore
- [ ] AppStore uses `@Observable` instead of `ObservableObject`
- [ ] All manual tests pass, no regressions
- [ ] `docs/00-master-plan.md` updated with completion status
