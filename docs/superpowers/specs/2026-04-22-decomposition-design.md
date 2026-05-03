# LaunchNext Decomposition Design (V1.1)

## Problem

LaunchNext is a monolithic single-target macOS app. `AppStore.swift` alone is 6,674 lines with 105 `@Published` properties handling scanning, caching, persistence, folder management, dragging, ordering, importing, updates, sound, hot corners, and more. The codebase has **44 Swift files (~35.8K lines)** with no module boundaries — every file sees every other file, and a change to any file recompiles everything.

## Goals

1. **Code maintainability**: Break AppStore into focused managers/actors with single responsibilities
2. **Build performance**: Create Tuist framework targets so modules compile independently
3. **Gradual migration**: Start with delegate extraction (low risk), promote to independent stores over time

## Approach: Mixed Delegate + Multi-Store

- **Phase 1**: Extract logic from AppStore into child classes/actors in a `Services` module. AppStore retains its `@Published` properties but delegates work to the new managers. Views don't change.
- **Phase 2** (future): Gradually promote stable managers to independent `@Observable` stores injected directly into views, shrinking AppStore further.

## Module Architecture

```
LaunchNext (app target) — thin shell, wires everything together
│
├── LaunchNextCore (framework) — data models, protocols, zero internal deps
│   ├── AppInfo.swift
│   ├── FolderInfo.swift (LaunchpadItem enum moves here)
│   ├── PageEntryData.swift (SwiftData model)
│   ├── TopItemData.swift (SwiftData model)
│   ├── PerformanceMode.swift
│   ├── GeometryUtils.swift
│   ├── Localization.swift
│   └── AppStoreServiceDelegate.swift (protocol — see §Circular Dependency)
│
├── LaunchNextUtilities (framework) — shared helpers, depends on Core
│   ├── Animations.swift
│   ├── Extensions.swift
│   ├── LayoutPresetCatalog.swift
│   └── Markdown/ (3 files)
│
├── LaunchNextStrategies (framework) — pluggable algorithms, depends on Core
│   ├── SearchStrategy.swift
│   ├── LayoutStrategy.swift
│   └── ContextMenu/ (7 files)
│
├── LaunchNextInput (framework) — input subsystems, depends on Core
│   ├── Gesture/ (4 files)
│   ├── HotCornerMonitor.swift
│   └── ControllerInputManager.swift
│
├── LaunchNextServices (framework) — business logic, depends on Core + Utilities
│   ├── AppScanner.swift        (extracted from AppStore ~500 lines)
│   ├── AppCacheManager.swift   (existing 395 lines)
│   ├── IconStore.swift         (existing 55 lines)
│   ├── OrderPersistence.swift  (extracted from AppStore ~400 lines)
│   ├── FolderManager.swift     (extracted from AppStore ~600 lines)
│   ├── AppImportService.swift  (merged from AppStore + NativeLaunchpadImporter)
│   ├── UpdateChecker.swift     (extracted from AppStore ~200 lines)
│   ├── SoundManager.swift      (existing 122 lines)
│   └── VoiceManager.swift      (existing 138 lines)
│
├── LaunchNextGrid (framework) — CA rendering engine, depends on Core
│   ├── CAGridView.swift
│   ├── CAGridView+Input.swift
│   ├── CAGridView+Layout.swift
│   └── CAGridViewRepresentable.swift
│
├── LaunchNextUI (framework) — SwiftUI views, depends on Core + Services
│   ├── LaunchpadView.swift
│   ├── FolderView.swift
│   ├── SettingsView.swift
│   ├── LaunchpadItemButton.swift
│   └── RightClickMenu.swift
│
└── LaunchNextCLI (framework) — CLI/TUI logic, depends on Core
    ├── LaunchNextCLI.swift       (1,126 lines)
    └── LaunchNextCLIIPC.swift    (311 lines)
```

## Circular Dependency Resolution: AppStoreServiceDelegate

**Problem**: Extracted managers (e.g., `AppScanner`, `OrderPersistence`) need to write to `AppStore`'s `@Published` properties. But managers live in `LaunchNextServices` and `AppStore` lives in the App target. Services cannot import the App target.

**Solution**: Define a delegation protocol in `LaunchNextCore` (which both layers can see). Managers interact only with this protocol. `AppStore` (in App target) conforms and passes `self`.

```swift
// In LaunchNextCore/AppStoreServiceDelegate.swift
@MainActor
protocol AppStoreServiceDelegate: AnyObject {
    // AppScanner writes
    func applyScanResults(_ apps: [AppInfo], missing: Set<String>, hidden: Set<String>)
    func triggerObjectWillChange()

    // OrderPersistence writes
    func applyOrderedItems(_ items: [Page: [LaunchpadItem]], folders: [FolderInfo])

    // FolderManager writes
    func applyFolderChanges(_ folders: [FolderInfo], items: [Page: [LaunchpadItem]])

    // UpdateChecker writes
    func applyUpdateState(available: Bool, version: String?, url: URL?)

    // Shared access — managers read current state
    var currentApps: [AppInfo] { get }
    var currentFolders: [FolderInfo] { get }
    var currentItems: [Page: [LaunchpadItem]] { get }
}
```

```swift
// In App target — AppStore conforms
@MainActor final class AppStore: ObservableObject, AppStoreServiceDelegate {
    // ... @Published properties stay here ...

    func applyScanResults(_ apps: [AppInfo], missing: Set<String>, hidden: Set<String>) {
        self.apps = apps
        self.missingPlaceholders = missing
        self.hiddenAppPaths = hidden
    }

    func triggerObjectWillChange() {
        objectWillChange.send()
    }
    // ... other conformance methods ...
}
```

```swift
// In LaunchNextServices — Manager takes delegate, not AppStore
@MainActor final class AppScanner {
    weak var delegate: AppStoreServiceDelegate?

    func scanApplications() {
        // ... scanning logic ...
        delegate?.applyScanResults(results, missing: missingSet, hidden: hiddenSet)
    }
}
```

This ensures the dependency arrow stays one-directional: `Services → Core ← App`. No circular imports.

## Complete 1:1 File-to-Target Mapping

### LaunchNextCore (7 files, ~6,526 lines)

| File | Lines | Notes |
|------|-------|-------|
| `AppInfo.swift` | 182 | Data model |
| `FolderInfo.swift` | 334 | Data model, LaunchpadItem enum |
| `PerformanceMode.swift` | 24 | Enum |
| `GeometryUtils.swift` | 91 | Shared geometry math |
| `Localization.swift` | 5,840 | **Tech debt**: monolithic 17-language dictionary (see §Tech Debt) |
| `AppStoreServiceDelegate.swift` | ~55 | **New file**: delegation protocol |

*Note: `PageEntryData.swift` and `TopItemData.swift` (SwiftData models) will be added when SwiftData persistence is extracted in Phase 2.*

### LaunchNextUtilities (6 files, ~729 lines)

| File | Lines | Notes |
|------|-------|-------|
| `Animations.swift` | 44 | Animation presets |
| `Extensions.swift` | 38 | Color, Font, View extensions |
| `LayoutPresetCatalog.swift` | 110 | Layout preset definitions |
| `Markdown/MarkdownRenderModel.swift` | 33 | Markdown block types |
| `Markdown/ReleaseNotesMarkdownView.swift` | 267 | Release notes renderer |
| `Markdown/SimpleMarkdownParser.swift` | 237 | Custom markdown parser |

### LaunchNextStrategies (9 files, ~322 lines)

| File | Lines | Notes |
|------|-------|-------|
| `SearchStrategy.swift` | 64 | Search protocol + debounce/throttle |
| `LayoutStrategy.swift` | 74 | Layout protocol + page calculation |
| `ContextMenu/ContextMenuAction.swift` | 32 | Action protocol |
| `ContextMenu/ContextMenuActionRegistry.swift` | 51 | Action registry |
| `ContextMenu/AddToDockAction.swift` | 26 | Dock action |
| `ContextMenu/GetInfoAction.swift` | 14 | Finder Get Info |
| `ContextMenu/HideFromLaunchNextAction.swift` | 13 | Hide app action |
| `ContextMenu/ShowInFinderAction.swift` | 14 | Reveal in Finder |
| `ContextMenu/UninstallAction.swift` | 16 | Uninstall action |

### LaunchNextInput (7 files, ~920 lines)

| File | Lines | Notes |
|------|-------|-------|
| `Gesture/GestureConfiguration.swift` | 24 | Detection parameters |
| `Gesture/GestureMonitor.swift` | 91 | High-level gesture wrapper |
| `Gesture/HIDGestureMonitor.swift` | 352 | Low-level CGEventTap monitor |
| `Gesture/GestureStateMachine.swift` | 7 | GestureTriggerAction enum |
| `HotCornerMonitor.swift` | 144 | Hot corner detection |
| `ControllerInputManager.swift` | 297 | Game controller input |

### LaunchNextServices (9 files, ~2,565 lines)

| File | Lines | Notes |
|------|-------|-------|
| `AppCacheManager.swift` | 394 | Icon/info caching |
| `IconStore.swift` | 55 | NSCache icon store |
| `SoundManager.swift` | 122 | Sound playback |
| `VoiceManager.swift` | 138 | Voice feedback |
| `AppScanner.swift` | **~500** | **New**: extracted from AppStore |
| `OrderPersistence.swift` | **~400** | **New**: extracted from AppStore |
| `FolderManager.swift` | **~600** | **New**: extracted from AppStore |
| `AppImportService.swift` | **~300** | **New**: merged from AppStore + NativeLaunchpadImporter |
| `UpdateChecker.swift` | **~200** | **New**: extracted from AppStore |

*4 existing files move as-is. 5 new files are extracted from AppStore.*

### LaunchNextGrid (4 files, ~3,497 lines)

| File | Lines | Notes |
|------|-------|-------|
| `CAGridView.swift` | 831 | Core Animation grid |
| `CAGridView+Input.swift` | 1,769 | Mouse/keyboard handling |
| `CAGridView+Layout.swift` | 508 | Layer management/layout |
| `CAGridViewRepresentable.swift` | 389 | SwiftUI NSViewRepresentable |

### LaunchNextUI (5 files, ~10,472 lines)

| File | Lines | Notes |
|------|-------|-------|
| `LaunchpadView.swift` | 3,557 | Main launchpad view |
| `FolderView.swift` | 728 | Folder popover view |
| `SettingsView.swift` | 5,732 | **Tech debt**: should split into sub-views (see §Tech Debt) |
| `LaunchpadItemButton.swift` | 252 | Item button component |
| `RightClickMenu.swift` | 203 | Context menu helpers |

### LaunchNextCLI (2 files, ~1,437 lines)

| File | Lines | Notes |
|------|-------|-------|
| `LaunchNextCLI.swift` | 1,126 | CLI command definitions, request/response types |
| `LaunchNextCLIIPC.swift` | 311 | Unix domain socket IPC |

### LaunchNext App Target (2 files, ~8,540 lines → ~800 lines after extraction)

| File | Lines | Notes |
|------|-------|-------|
| `AppStore.swift` | 6,674 → ~800 | Facade after extraction |
| `LaunchpadApp.swift` | 1,866 | AppDelegate + window management |

### Summary

| Target | Files | Lines | New/Extracted |
|--------|-------|-------|---------------|
| Core | 6+1 new | ~6,526 | 1 new (delegate protocol) |
| Utilities | 6 | ~729 | 0 |
| Strategies | 9 | ~322 | 0 |
| Input | 6 | ~915 | 0 |
| Services | 4+5 new | ~2,565 | 5 new (extracted from AppStore) |
| Grid | 4 | ~3,497 | 0 |
| UI | 5 | ~10,472 | 0 |
| CLI | 2 | ~1,437 | 0 |
| App | 2 | ~8,540 | 0 |
| **Total** | **44+6 new = 50** | **~35,003** | **6 new files** |

## AppStore Decomposition Detail

AppStore.swift goes from 6,674 lines to ~800 lines. It becomes a thin facade:

```swift
@MainActor final class AppStore: ObservableObject, AppStoreServiceDelegate {
    // Keeps all @Published properties (views bind to them)
    @Published var apps: [AppInfo] = []
    @Published var folders: [FolderInfo] = []
    @Published var items: [Page: [LaunchpadItem]] = [:]
    // ... all 105 @Published properties stay here for now

    // Delegates to extracted managers
    let scanner: AppScanner
    let cache: AppCacheManager
    let persistence: OrderPersistence
    let folderManager: FolderManager
    let importer: AppImportService
    let updateChecker: UpdateChecker

    init() {
        scanner = AppScanner(delegate: self)
        cache = AppCacheManager()
        persistence = OrderPersistence(delegate: self)
        folderManager = FolderManager(delegate: self)
        importer = AppImportService(delegate: self)
        updateChecker = UpdateChecker(delegate: self)
    }
}
```

### Extracted Managers

#### AppScanner (~500 lines, from AppStore)
- `scanApplications()`, `scanApplicationsInBackground()`
- `applyIncrementalChanges()`, `isValidApp(at:)`, `isInsideAnotherApp`
- FSEventStream lifecycle (already uses FSEventContextBox wrapper)
- Fallback periodic scan timer
- Writes to delegate: `applyScanResults()`, `triggerObjectWillChange()`
- Reads from delegate: `currentApps`

#### OrderPersistence (~400 lines, from AppStore)
- `persistPageOrder()`, `loadPersistedOrder()`
- `exportOrder()`, `importOrder()`
- `rebuildItemsPreservingOrder()`, smart merge logic
- SwiftData model interaction
- Writes to delegate: `applyOrderedItems()`

#### FolderManager (~600 lines, from AppStore)
- `createFolder()`, `deleteFolder()`, `updateFolder()`
- `moveAppToFolder()`, `removeAppFromFolder()`
- Cross-page drag logic
- Auto-create/delete empty pages
- Writes to delegate: `applyFolderChanges()`

#### AppImportService (~300 lines, merged from AppStore + NativeLaunchpadImporter)
- `importFromLaunchpad()` — absorbs NativeLaunchpadImporter.swift logic
- `importFromArchive()`
- Database detection and parsing

#### UpdateChecker (~200 lines, from AppStore)
- `checkForUpdates()`, `downloadUpdate()`
- GitHub release parsing
- Already mostly self-contained
- Writes to delegate: `applyUpdateState()`

## Tuist Project.swift Structure

```swift
// Project.swift
let project = Project(
    name: "LaunchNext",
    settings: ...,
    targets: [
        // App target — thin shell
        .target(name: "LaunchNext", dependencies: [
            .target(name: "LaunchNextCore"),
            .target(name: "LaunchNextUtilities"),
            .target(name: "LaunchNextStrategies"),
            .target(name: "LaunchNextInput"),
            .target(name: "LaunchNextServices"),
            .target(name: "LaunchNextGrid"),
            .target(name: "LaunchNextUI"),
            .target(name: "LaunchNextCLI"),
        ]),
        // Frameworks
        .target(name: "LaunchNextCore", ...),
        .target(name: "LaunchNextUtilities", dependencies: [
            .target(name: "LaunchNextCore")
        ]),
        .target(name: "LaunchNextStrategies", dependencies: [
            .target(name: "LaunchNextCore")
        ]),
        .target(name: "LaunchNextInput", dependencies: [
            .target(name: "LaunchNextCore")
        ]),
        .target(name: "LaunchNextServices", dependencies: [
            .target(name: "LaunchNextCore"),
            .target(name: "LaunchNextUtilities"),
        ]),
        .target(name: "LaunchNextGrid", dependencies: [
            .target(name: "LaunchNextCore")
        ]),
        .target(name: "LaunchNextUI", dependencies: [
            .target(name: "LaunchNextCore"),
            .target(name: "LaunchNextServices"),
        ]),
        .target(name: "LaunchNextCLI", dependencies: [
            .target(name: "LaunchNextCore")
        ]),
    ]
)
```

## Dependency Graph

```
Core ← Utilities ← Services ← App
Core ← Strategies           ← App
Core ← Input                ← App
Core ← Grid                 ← App
Core ← UI ← Services        ← App
Core ← CLI                  ← App
```

No circular dependencies. Core has zero internal deps. Services is the deepest at 2 hops. All arrows point toward Core.

## Public API Surface Strategy

Moving to frameworks forces many `internal` symbols to become `public`. Strategy:

1. **Core**: Most types must be `public` (used by every other module). Keep computed properties and internal helpers `internal` where possible.
2. **Services**: Only facade methods called by AppStore need `public`. Manager internals stay `internal`.
3. **Strategies/Input/Grid**: Protocol definitions and integration points are `public`. Implementation details stay `internal`.
4. **UI**: View structs must be `public`. Internal helpers and view modifiers stay `internal`.
5. **Utilities**: Utility functions used across modules are `public`. Internal helpers stay `internal`.

Rule of thumb: default to `internal`, promote to `public` only when the compiler requires it.

## Migration Strategy: Leaf-First Extraction

### Step 1: Core + Utilities (no dependencies)
1. Create `LaunchNextCore` target, move 6 files
2. Create `LaunchNextUtilities` target, move 6 files
3. Add `import LaunchNextCore` where needed
4. Create `AppStoreServiceDelegate.swift` in Core
5. **Verify**: `tuist generate --no-open` + `xcodebuild build`

### Step 2: Leaf Services (self-contained, low risk)
1. Create `LaunchNextServices` target
2. Move `AppCacheManager.swift`, `IconStore.swift`, `SoundManager.swift`, `VoiceManager.swift` as-is
3. **Verify**: build

### Step 3: Strategies + Input + CLI + Grid (no AppStore dependency)
1. Create `LaunchNextStrategies`, `LaunchNextInput`, `LaunchNextCLI`, `LaunchNextGrid` targets
2. Move files into module directories
3. **Verify**: build

### Step 4: Extract AppStore Managers (the hard part)
1. Extract `AppScanner` from AppStore — conforms to `AppStoreServiceDelegate` pattern
2. Extract `OrderPersistence` from AppStore
3. Extract `FolderManager` from AppStore
4. Merge `NativeLaunchpadImporter` + AppStore import code → `AppImportService`
5. Extract `UpdateChecker` from AppStore
6. AppStore becomes thin facade (~800 lines)
7. **Verify**: build + functional test after each extraction

### Step 5: UI Module
1. Create `LaunchNextUI` target
2. Move 5 view files
3. **Verify**: build + visual regression test

## Tech Debt Acknowledgments

### Localization.swift (5,840 lines in Core)
This is a compilation bottleneck — every module depends on Core, so any change to Localization forces a full rebuild. **Accepted as tech debt for Phase 1.** Future options:
- Split into per-language files loaded at runtime
- Extract to a standalone `LaunchNextLocalization` framework
- Convert to String Catalogs (.xcstrings)

### SettingsView.swift (5,732 lines in UI)
This is a monolithic settings view with 15+ sections. **Accepted as tech debt for Phase 1.** Future split:
- `AppearanceSettingsView`, `LayoutSettingsView`, `SoundSettingsView`, `GestureSettingsView`, etc.
- Shared `SettingsComponents` for common controls

## Testing Strategy

Add `.unitTests` targets for critical modules in Phase 2:

```swift
.target(name: "LaunchNextServicesTests", dependencies: [
    .target(name: "LaunchNextServices"),
]),
.target(name: "LaunchNextStrategiesTests", dependencies: [
    .target(name: "LaunchNextStrategies"),
]),
```

Phase 1 verification is manual (build + launch + functional test). Automated tests come with Phase 2 when managers are fully independent.

## Verification (per step)

After each step:
1. `mise exec tuist@latest -- tuist generate --no-open` succeeds
2. `xcodebuild build` succeeds
3. No new warnings introduced
4. LaunchNext app launches and functions identically

## Changes from V1.0

| Issue | V1.0 | V1.1 |
|-------|------|------|
| C1: Circular Dependency | Managers held `weak var appStore: AppStore?` | `AppStoreServiceDelegate` protocol in Core; managers use `weak var delegate` |
| C2: Ghost Code | LaunchpadApp, CLI, NativeLaunchpadImporter unmapped | Complete 1:1 mapping for all 44+ files |
| C3: File Count | "38 files, ~32.5K lines" | **44 files, ~35.8K lines** |
| I1: Localization | Listed in Core without comment | Tech debt acknowledged with mitigation plan |
| I2: Public API | Not addressed | Public API surface strategy added |
| I3: Testing | "Verification" section only | Testing strategy section added, unit tests deferred to Phase 2 |
| M2: Migration Order | No specific sequence | Leaf-first extraction ordering (5 steps) |
| CLI Module | Missing | `LaunchNextCLI` framework added |
| NativeLaunchpadImporter | Listed as existing file | Merged into `AppImportService` during extraction |
