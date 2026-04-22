# LaunchNext Decomposition Design

## Problem

LaunchNext is a monolithic single-target macOS app. `AppStore.swift` alone is 6,674 lines with 105 `@Published` properties handling scanning, caching, persistence, folder management, dragging, ordering, importing, updates, sound, hot corners, and more. The codebase has 38 Swift files (~32.5K lines) with no module boundaries — every file sees every other file, and a change to any file recompiles everything.

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
├── LaunchNextCore (framework) — data models, zero internal deps
│   ├── AppInfo.swift
│   ├── FolderInfo.swift (LaunchpadItem enum moves here)
│   ├── PageEntryData.swift (SwiftData model)
│   ├── TopItemData.swift (SwiftData model)
│   ├── PerformanceMode.swift
│   ├── GeometryUtils.swift
│   └── Localization.swift
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
│   ├── AppImportService.swift  (extracted from AppStore + NativeLaunchpadImporter)
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
└── LaunchNextUI (framework) — SwiftUI views, depends on Core + Services
    ├── LaunchpadView.swift
    ├── FolderView.swift
    ├── SettingsView.swift
    ├── LaunchpadItemButton.swift
    └── RightClickMenu.swift
```

## AppStore Decomposition Detail

AppStore.swift goes from 6,674 lines to ~500-800 lines. It becomes a thin facade:

```
@MainActor final class AppStore: ObservableObject {
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

    init() { ... }  // Creates managers, wires bindings
}
```

### Extracted Managers

#### AppScanner (~500 lines, from AppStore)
- `scanApplications()`, `scanApplicationsInBackground()`
- `applyIncrementalChanges()`, `isValidApp(at:)`, `isInsideAnotherApp`
- FSEventStream lifecycle (already uses wrapper pattern)
- Fallback periodic scan timer
- Published properties it writes to AppStore: `apps`, `missingPlaceholders`, `hiddenAppPaths`

#### OrderPersistence (~400 lines, from AppStore)
- `persistPageOrder()`, `loadPersistedOrder()`
- `exportOrder()`, `importOrder()`
- `rebuildItemsPreservingOrder()`, smart merge logic
- SwiftData model interaction

#### FolderManager (~600 lines, from AppStore)
- `createFolder()`, `deleteFolder()`, `updateFolder()`
- `moveAppToFolder()`, `removeAppFromFolder()`
- Cross-page drag logic
- Auto-create/delete empty pages

#### AppImportService (~300 lines, merged from AppStore + NativeLaunchpadImporter)
- `importFromLaunchpad()`
- `importFromArchive()`
- Database detection and parsing

#### UpdateChecker (~200 lines, from AppStore)
- `checkForUpdates()`, `downloadUpdate()`
- GitHub release parsing
- Already mostly self-contained

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
        ]),
        // Frameworks
        .target(name: "LaunchNextCore", ...),
        .target(name: "LaunchNextUtilities", dependencies: [.target(name: "LaunchNextCore")]),
        .target(name: "LaunchNextStrategies", dependencies: [.target(name: "LaunchNextCore")]),
        .target(name: "LaunchNextInput", dependencies: [.target(name: "LaunchNextCore")]),
        .target(name: "LaunchNextServices", dependencies: [
            .target(name: "LaunchNextCore"),
            .target(name: "LaunchNextUtilities"),
        ]),
        .target(name: "LaunchNextGrid", dependencies: [.target(name: "LaunchNextCore")]),
        .target(name: "LaunchNextUI", dependencies: [
            .target(name: "LaunchNextCore"),
            .target(name: "LaunchNextServices"),
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
```

No circular dependencies. Core has no internal deps. Services is the deepest at 2 hops.

## Migration Strategy

### Phase 1: Extract + Delegate (this PR)
1. Create Tuist module targets with proper `sources` globs
2. Move files into module directories
3. Add `import LaunchNextCore` etc. where needed
4. Extract `AppScanner`, `OrderPersistence`, `FolderManager`, `UpdateChecker` from AppStore
5. AppStore creates and delegates to these managers
6. All `@Published` properties stay on AppStore — views unchanged

### Phase 2: Multi-Store (future)
- Promote `SettingsStore` (all appearance/behavior settings)
- Promote `ScannerStore` (apps, folders, items)
- Inject directly into views via environment
- AppStore shrinks to coordination layer

## Verification

After each extracted module:
1. `tuist generate --no-open` succeeds
2. `xcodebuild build` succeeds
3. No new warnings introduced
4. LaunchNext app launches and functions identically

## Files Modified/Created

### New files (extracted managers):
- `LaunchNext/Services/AppScanner.swift`
- `LaunchNext/Services/OrderPersistence.swift`
- `LaunchNext/Services/FolderManager.swift`
- `LaunchNext/Services/UpdateChecker.swift`

### Significantly modified:
- `AppStore.swift` (6,674 → ~800 lines)
- `Project.swift` (multi-target Tuist config)

### Moved (not modified in content):
- All 38 existing files move into module subdirectories
- `Info.plist` entries updated per target
