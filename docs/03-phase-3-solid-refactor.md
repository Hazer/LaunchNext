# Phase 3: Full SOLID Refactor

**Status:** Not started
**Depends on:** Phase 2 complete

## Scope

Dependency injection, protocol abstractions, TCA adoption decision, command pattern for CLI.

**Risk:** Higher — larger structural changes, potential API surface changes.

---

## 3.1 Protocol-Based Dependency Injection

### Problem
Every view directly depends on the concrete `AppStore` class. `AppDelegate.shared` is accessed directly from CAGridViewRepresentable and other views. This makes testing difficult and violates the Dependency Inversion Principle.

### Approach
- Define `AppStoreProtocol` with read-only properties that views actually need
- Views accept the protocol instead of the concrete type
- Use SwiftUI's `@Environment` for dependency injection
- `AppDelegate.shared` access is eliminated — views receive dependencies through environment

**Example:**
```swift
protocol AppStoreProtocol: ObservableObject {
    var items: [LaunchpadItem] { get }
    var currentPage: Int { get set }
    var searchText: String { get set }
    var layoutMode: LayoutMode { get }
    // ... only what views actually need
}
```

### Files
- **New:** `Protocols/AppStoreProtocol.swift`
- **Modified:** All view files — inject via protocol

### Testing
- Mock `AppStoreProtocol` for view unit tests
- Verify all views render with mock data

---

## 3.2 TCA Adoption Decision

### Problem
The codebase needs a clear pattern for state management. TCA provides:
- Strict unidirectional data flow (state → actions → effects)
- Testable reducers (pure functions)
- Composable features
- Built-in dependency injection via `Store`

### Decision Point
After Phase 2, evaluate:
1. Are the plain coordinators + `@Observable` working well?
2. Is the state management complex enough to benefit from TCA's structure?
3. Would TCA's boilerplate be worth it for this codebase size?

### If Adopting TCA
- Migrate view models to TCA features (reducers)
- `Store` replaces `@Observable` classes
- Effects handle async operations (scanning, FSEvents)
- `@Bindable` in views

### If Staying Vanilla
- Keep `@Observable` + coordinators
- Add `Equatable` conformance where needed for optimized re-renders
- Document the chosen architecture pattern

### Files
- Depends on decision — see above

---

## 3.3 Command Pattern for CLI

### Problem
CLI command handler is a large `switch` statement (20+ cases) in `CLICoordinator`. Adding new commands requires modifying the switch.

### Approach
- `CLICommand` protocol:
```swift
protocol CLICommand: Sendable {
    var name: String { get }
    func execute(context: CLIContext) async -> CLIResult
}
```
- `CLICommandRegistry`: registers and dispatches commands by name
- Each command is its own struct in its own file
- Adding a new command = adding a new file, no modification to registry

### Files
- **New:** `CLI/CLICommand.swift`, `CLI/CLICommandRegistry.swift`
- **New:** `CLI/Commands/*.swift` (one per command)
- **Modified:** `Coordinators/CLICoordinator.swift` — use registry instead of switch

### Testing
- Each command is testable in isolation
- Registry correctly dispatches by name
- Unknown commands return proper error

---

## Phase 3 Exit Criteria
- [ ] Views depend on `AppStoreProtocol`, not concrete `AppStore`
- [ ] CLI uses command pattern (extensible without modification)
- [ ] TCA decision documented and implemented (or consciously deferred with rationale)
- [ ] `docs/00-master-plan.md` updated with completion status
