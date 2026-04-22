# LaunchNext Phase 2: Manager Extraction + SettingsStore

**Date:** 2026-04-22
**Status:** DRAFT
**Depends on:** Phase 1 (complete — 5 framework targets extracted)

## Context

Phase 1 extracted 21 standalone files into 5 Tuist framework targets (Core, Utilities, Input, Strategies, CLI). The app target still has 24 files, with `AppStore.swift` at 6,677 lines and 102 `@Published` properties. This phase shrinks AppStore to ~1,500 lines by extracting 5 operational managers and grouping 76 settings properties into a SettingsStore.

## Scope

- **Phase 2 (this spec):** Extract managers + SettingsStore. AppStore becomes thin facade.
- **Phase 3 (future):** Promote independent stores, move Grid/Services/UI into frameworks.

## Architecture After Phase 2

```
AppStore (facade, ~1,500 lines)
├── @Published var apps, folders, items (core state)
├── @Published var currentPage, searchText, openFolder (UI state)
├── @Published var folderUpdateTrigger, gridRefreshTrigger (triggers)
├── let settingsStore: SettingsStore       (76 settings properties)
├── let scanner: AppScanner                (delegates to AppStoreServiceDelegate)
├── let persistence: OrderPersistence      (delegates to AppStoreServiceDelegate)
├── let folderManager: FolderManager       (delegates to AppStoreServiceDelegate)
├── let importer: AppImportService         (delegates to AppStoreServiceDelegate)
└── let updateChecker: UpdateChecker       (delegates to AppStoreServiceDelegate)
```

All managers live in the app target (same module as AppStore). Framework extraction is Phase 3.

## AppStoreServiceDelegate Protocol

The protocol in `LaunchNextCore/AppStoreServiceDelegate.swift` expands to cover all manager needs:

```swift
@MainActor
protocol AppStoreServiceDelegate: AnyObject {
    // State writes
    func applyScanResults(_ apps: [AppInfo],
                          missing: [String: MissingAppPlaceholder],
                          hidden: Set<String>)
    func applyOrderedItems(_ items: [LaunchpadItem], folders: [FolderInfo])
    func applyFolderChanges(_ folders: [FolderInfo], items: [LaunchpadItem])
    func applyUpdateState(_ state: UpdateState)

    // UI triggers
    func triggerObjectWillChange()
    func triggerGridRefresh()
    func triggerFolderUpdate()
    func refreshCacheAfterFolderOperation()

    // State reads
    var currentApps: [AppInfo] { get }
    var currentFolders: [FolderInfo] { get }
    var currentItems: [LaunchpadItem] { get }
    var currentHiddenAppPaths: Set<String> { get }
    var currentMissingPlaceholders: [String: MissingAppPlaceholder] { get }

    // Layout helpers (shared across managers)
    func compactItemsWithinPages() -> [LaunchpadItem]
    func removeEmptyPages() -> [LaunchpadItem]
    func filteredItemsRemovingHidden(from items: [LaunchpadItem]) -> [LaunchpadItem]
    func sanitizedFolders(_ folders: [FolderInfo]) -> [FolderInfo]

    // Cross-manager routing
    func persistenceSaveAllOrder()
    func persistenceLoadAllOrder()
    func persistenceRebuildItems()
}
```

### Types Moved to Core

The following types are currently nested in AppStore and must move to `LaunchNextCore` so managers can reference them:

- `UpdateState` enum (currently `AppStore.UpdateState`)
- `UpdateRelease` struct
- `GitHubRelease` struct
- `SemanticVersion` helper (if not already standalone)

## Extracted Managers

### 1. UpdateChecker (~250 lines)

**Extraction order:** First (proof of concept, no cross-manager dependencies)

**Methods:**
- `checkForUpdates()`, `getCurrentVersion()`, `fetchLatestRelease()`
- `presentUpdateAlert(for:)`, `presentUpdateFailureAlert(_:)`
- `launchUpdater(for:)`, `startUpdaterProcess(tag:)`
- `performAutomaticUpdateCheckIfNeeded()`, `scheduleAutomaticUpdateCheck()`
- `ensureUpdateNotificationSetup()`, `enqueueUpdateNotification(title:body:releaseURL:)`
- `sendTestUpdateNotification()`

**State reads/writes via delegate:**
- Writes: `applyUpdateState(_:)`
- Reads: settings via `UserDefaults` directly (autoCheckForUpdates, lastUpdateCheck)

**Dependencies:** URLSession, UNUserNotificationCenter, GitHub API, SwiftUpdater binary

**AppStore conformance:**
```swift
func applyUpdateState(_ state: UpdateState) {
    self.updateState = state
}
```

### 2. OrderPersistence (~500 lines)

**Extraction order:** Second (needed by scanner, folder manager, importer)

**Methods:**
- `loadAllOrder()`, `saveAllOrder()`
- `loadOrderFromPageEntries(using:)`, `loadOrderFromLegacyTopItems(using:)`
- `rebuildItems()`, `rebuildItemsWithStrictOrderPreservation(currentItems:)`
- `mergeCurrentOrderWithPersistedData(currentItems:newApps:loadPersistedFolders:)`
- `loadFoldersFromPersistedData()`, `hasPersistedOrderData()`

**State reads/writes via delegate:**
- Reads: `currentApps`, `currentItems`, `currentFolders`
- Writes: `applyOrderedItems(_, folders:)`

**Dependencies:** SwiftData ModelContext, PageEntryData, TopItemData, FileManager

**Additional delegate needs:**
- `removableSourcePath(forAppPath:)` — path utility
- `updateMissingPlaceholder(path:displayName:removableSource:)` — missing app tracking
- `clearMissingPlaceholder(for:)` — cleanup
- `appInfo(from:preferredName:loadIcon:)` — factory method
- `standardizedFilePath(_:)` — path utility

**Cross-manager routing:** AppStore routes `persistenceSaveAllOrder()` to `persistence.saveAllOrder()`.

### 3. AppScanner (~400 lines)

**Extraction order:** Third (depends on OrderPersistence)

**Methods:**
- `scanApplications(loadPersistedOrder:)`, `scanApplicationsWithOrderPreservation()`
- `forceFullRescan()`, `performImmediateRefresh()`
- `applyIncrementalChanges(for:)`, `processScannedApplications(_:)`
- `startAutoRescan()`, `stopAutoRescan()`, `restartAutoRescan()`
- `handleFSEvents(paths:flagsPointer:count:)`
- `setupVolumeObservers()`, `handleVolumeEvent(at:isMount:)`
- `performFallbackScanIfNeeded()`, `startFallbackScanTimer()`, `stopFallbackScanTimer()`
- `isValidApp(at:)`, `isInsideAnotherApp(_:)` (helper methods)
- `normalizeApplicationPath(_:)`, `standardizedFilePath(_:)` (path utils)

**State reads/writes via delegate:**
- Writes: `applyScanResults(_, missing:, hidden:)`
- Reads: `currentApps`, `currentHiddenAppPaths`
- Calls: `persistenceLoadAllOrder()`, `persistenceSaveAllOrder()`, `persistenceRebuildItems()`

**Dependencies:** FSEventStream, FileManager, NSWorkspace, DispatchQueues

**Special:** Takes ownership of `FSEventContextBox` (nested class) and the FSEventStream lifecycle.

### 4. FolderManager (~350 lines)

**Extraction order:** Fourth (depends on OrderPersistence)

**Methods:**
- `createFolder(with:name:)`, `createFolder(with:name:insertAt:)`
- `addAppToFolder(_:folder:)`, `removeAppFromFolder(_:folder:)`
- `renameFolder(_:newName:)`, `dissolveFolder(_:)`
- `moveItemAcrossPagesWithCascade(item:to:)`
- `moveSelectedAppsAcrossPagesWithCascade(appPathsOrdered:to:)`
- `cascadeInsert(into:item:at:)`

**State reads/writes via delegate:**
- Reads: `currentApps`, `currentItems`, `currentFolders`
- Writes: `applyFolderChanges(_, items:)`
- Calls: `persistenceSaveAllOrder()`, `triggerFolderUpdate()`, `triggerGridRefresh()`
- Calls: `compactItemsWithinPages()`, `removeEmptyPages()`

**Dependencies:** None external — operates on LaunchpadItem/FolderInfo arrays.

### 5. AppImportService (~200 lines)

**Extraction order:** Fifth (depends on FolderManager, OrderPersistence)

**Methods:**
- `importFromNativeLaunchpad()`, `importFromLegacyLaunchpadArchive(url:)`
- `processImportedData(_:)`
- `applyMacOS26PresetLayout()`, `presetCandidateAppsInCurrentOrder()`
- `presetCandidate(from:path:)`, `matchPresetSlot(bundleIdentifiers:in:)`

**State reads/writes via delegate:**
- Reads: `currentApps`, `currentFolders`, `currentItems`
- Writes: `applyScanResults` or `applyOrderedItems` after import
- Calls: `persistenceLoadAllOrder()`, `persistenceSaveAllOrder()`

**Dependencies:** NativeLaunchpadImporter (existing class), LayoutPresetCatalog (in Utilities)

**Absorbs:** `NativeLaunchpadImporter.swift` (756 lines) merges into this service.

## SettingsStore (~800 lines)

A new `ObservableObject` holding all settings `@Published` properties currently on AppStore.

### Structure

The exact list of 76 settings properties will be enumerated during implementation by extracting all `@Published` properties from AppStore that are NOT in the "What Stays on AppStore" list below.

```swift
@MainActor
final class SettingsStore: ObservableObject {
    // Layout (12 properties)
    @Published var gridColumnsPerPage: Int
    @Published var gridRowsPerPage: Int
    @Published var iconColumnSpacing: Double
    @Published var iconRowSpacing: Double
    @Published var gridPadding: Double
    @Published var pageSpacing: Double
    @Published var itemsPerRow: Int
    // ...

    // Appearance (15 properties)
    @Published var iconScale: Double
    @Published var showLabels: Bool
    @Published var iconLabelFontSize: Double
    @Published var backgroundMaskEnabled: Bool
    // ...

    // Folders (3 properties)
    @Published var folderDropZoneScale: Double
    @Published var enableHighResFolderPreviews: Bool
    // ...

    // Animations (4 properties)
    @Published var enableAnimations: Bool
    @Published var animationDuration: Double
    @Published var enableHoverMagnification: Bool
    @Published var hoverMagnificationScale: Double
    // ...

    // Hotkey & Input (8 properties)
    @Published var globalHotKey: String
    @Published var hotCornerEnabled: Bool
    @Published var hotCornerPosition: Int
    // ...

    // Voice (3 properties)
    @Published var voiceEnabled: Bool
    @Published var voiceLanguage: String
    // ...

    // Sound (2 properties)
    @Published var soundEnabled: Bool
    // ...

    // Update (3 properties)
    @Published var autoCheckForUpdates: Bool
    // ...

    init() {
        let cache = DefaultsCache()
        // Read all settings from cache (same pattern as current AppStore init)
    }
}
```

### View Migration

All views that reference `appStore.enableAnimations` change to `appStore.settingsStore.enableAnimations`:
- `LaunchpadView.swift` — ~15 references
- `SettingsView.swift` — ~100+ references (main consumer)
- `FolderView.swift` — ~5 references
- `CAGridView*.swift` — ~10 references
- `LaunchpadItemButton.swift` — ~3 references

Search-replace: `appStore.enableAnimations` → `appStore.settingsStore.enableAnimations` (per property).

AppStore exposes the store:
```swift
@MainActor final class AppStore: ObservableObject {
    let settingsStore = SettingsStore()
    // ...
}
```

### What Stays on AppStore

Only core operational state:
- `apps: [AppInfo]`, `folders: [FolderInfo]`, `items: [LaunchpadItem]`
- `missingPlaceholders`, `hiddenAppPaths`, `customTitles`
- `currentPage`, `searchText`, `searchQuery`, `isSetting`
- `openFolder`, `isDragCreatingFolder`, drag state
- `folderUpdateTrigger`, `gridRefreshTrigger`, `iconCacheRefreshTrigger`
- `isInitialLoading`, `shouldShowOnboarding`
- `hasAppliedOrderFromStore`, `modelContext`

~26 `@Published` properties remain (down from 102).

## Extraction Order and Build Verification

### Step 1: UpdateChecker (proof of concept)
1. Move `UpdateState`, `UpdateRelease`, `GitHubRelease` to Core
2. Create `UpdateChecker.swift` in app target
3. Move update methods from AppStore to UpdateChecker
4. AppStore creates `updateChecker = UpdateChecker(delegate: self)`
5. Update `AppStoreServiceDelegate` protocol
6. **Verify:** build + update check triggers

### Step 2: OrderPersistence
1. Create `OrderPersistence.swift` in app target
2. Move persistence methods from AppStore
3. AppStore routes delegate calls to persistence
4. **Verify:** build + drag-reorder persists across restart

### Step 3: AppScanner
1. Create `AppScanner.swift` in app target
2. Move scanning methods, FSEventStream lifecycle, FSEventContextBox
3. AppScanner takes ownership of `fsEventsQueue`, `refreshQueue`
4. **Verify:** build + apps appear + file changes detected

### Step 4: FolderManager
1. Create `FolderManager.swift` in app target
2. Move folder CRUD methods, cross-page drag logic
3. **Verify:** build + folder create/dissolve/rename

### Step 5: AppImportService
1. Create `AppImportService.swift` in app target
2. Move import methods from AppStore + merge NativeLaunchpadImporter
3. Delete `NativeLaunchpadImporter.swift`
4. **Verify:** build + import from native Launchpad works

### Step 6: SettingsStore
1. Create `SettingsStore.swift` in app target
2. Move 76 `@Published` settings properties
3. Search-replace `appStore.X` → `appStore.settingsStore.X` in all views
4. **Verify:** build + Settings view works + all toggles functional

### Step 7: Cleanup
1. Remove dead code from AppStore
2. Verify AppStore is ~1,500 lines
3. Full functional regression test

## Phase 3 Outline (Future)

With AppStore at ~1,500 lines and managers extracted:

1. **Promote independent stores:**
   - `ScannerStore` (apps, folders, items — views observe directly)
   - `FolderStore` (folder operations — FolderView observes directly)

2. **Framework extraction:**
   - Grid → `LaunchNextGrid` (CAGridView no longer references AppStore directly)
   - Services → `LaunchNextServices` (managers now use delegate protocol)
   - UI → `LaunchNextUI` (views reference stores via protocol)

3. **AppStore final state:** ~300-line coordination layer wiring stores together.

## Files Modified/Created

### New files (in app target):
- `LaunchNext/UpdateChecker.swift` (~250 lines)
- `LaunchNext/OrderPersistence.swift` (~500 lines)
- `LaunchNext/AppScanner.swift` (~400 lines)
- `LaunchNext/FolderManager.swift` (~350 lines)
- `LaunchNext/AppImportService.swift` (~200 lines, absorbs NativeLaunchpadImporter)
- `LaunchNext/SettingsStore.swift` (~800 lines)

### Modified:
- `LaunchNext/AppStore.swift` (6,677 → ~1,500 lines)
- `LaunchNextCore/AppStoreServiceDelegate.swift` (expanded protocol)
- `LaunchNextCore/FolderInfo.swift` (UpdateState, GitHubRelease types added)
- `LaunchNext/LaunchpadView.swift` (settings access paths)
- `LaunchNext/SettingsView.swift` (settings access paths)
- `LaunchNext/FolderView.swift` (settings access paths)
- `LaunchNext/CAGridView*.swift` (settings access paths)
- `LaunchNext/LaunchpadItemButton.swift` (settings access paths)
- `LaunchNext/LaunchpadApp.swift` (settings access paths)

### Deleted:
- `LaunchNext/NativeLaunchpadImporter.swift` (merged into AppImportService)

### Line Count Impact

| Component | Before | After |
|-----------|--------|-------|
| AppStore.swift | 6,677 | ~1,500 |
| New managers | 0 | ~1,700 |
| SettingsStore | 0 | ~800 |
| NativeLaunchpadImporter | 756 | 0 (merged) |
| **Total** | **7,433** | **~4,000** |

Net reduction: ~3,400 lines removed through deduplication and extracting shared logic.
