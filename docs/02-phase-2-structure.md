# Phase 2: Structure — Coordinator Pattern + View Model Extraction

**Status:** Not started
**Depends on:** Phase 1 complete

## Scope

Split AppDelegate into focused coordinators, extract view models from LaunchpadView, split SettingsView into section files. Structural changes with no behavior changes.

**Risk:** Medium — larger diff but each extraction is independently testable.

---

## 2.1 Split AppDelegate into Coordinators

### Problem
`LaunchpadApp.swift` (AppDelegate) is 1886 lines with 12+ distinct responsibilities: window management, hot keys, gestures, CLI, menu bar, system UI, animation, sound, and more. It's a textbook God Class.

### Approach

Extract into focused coordinator classes. AppDelegate becomes ~200 lines of app lifecycle + wiring.

| Coordinator | Source Lines | Responsibility |
|------------|-------------|---------------|
| `WindowCoordinator` | ~300 | Window creation, show/hide/animation, system UI (dock/menubar), fullscreen mode, corner radius, frame calculation |
| `HotKeyCoordinator` | ~150 | Global hotkey registration, sync, unregister, Carbon API bridge |
| `GestureCoordinator` | ~80 | Gesture monitor lifecycle, magnify suppressor lifecycle, wake recovery |
| `CLICoordinator` | ~200 | CLI endpoint monitoring, IPC server, command dispatch, snapshot building |
| `MenuBarCoordinator` | ~80 | Status item creation, menu actions, show/hide logic |

### TCA Decision Point

After extraction, evaluate whether to adopt [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture):
- **If yes:** Migrate coordinators to TCA reducers/features, views use `@Bindable` + `Store`
- **If no:** Keep `@Observable` + plain classes (simpler, but less structured)

Decision will be based on how well the coordinator pattern works in practice.

### Files
- **New:** `Coordinators/WindowCoordinator.swift`
- **New:** `Coordinators/HotKeyCoordinator.swift`
- **New:** `Coordinators/GestureCoordinator.swift`
- **New:** `Coordinators/CLICoordinator.swift`
- **New:** `Coordinators/MenuBarCoordinator.swift`
- **Modified:** `LaunchpadApp.swift` — slim AppDelegate

### Testing
- Each coordinator can be unit tested in isolation (mock dependencies)
- Full integration test: all coordinator wiring works correctly
- No behavior change — same user experience

---

## 2.2 Extract View Models from LaunchpadView

### Problem
`LaunchpadView.swift` is 2000+ lines mixing view rendering, business logic, drag-and-drop state, pagination, and animation concerns. It has 30+ `@State` properties and complex computed properties (`filteredItems`, `pages`, `visualItems`) that belong in a view model.

### Approach

Extract two view models:

**`LaunchpadViewModel`** — manages all non-animation state:
- `filteredItems`, `pages`, `currentItems`, `visualItems` (pagination logic)
- Search state delegation
- Drag state: `draggingItem`, `pendingDropIndex`, `dragPreviewPosition`, `dragPreviewScale`
- Selection state: `selectedIndex`, `isKeyboardNavigationActive`
- Folder state: `isFolderOpen`, `openFolder`, `isFolderNameEditing`

**`DragDropViewModel`** — manages drag-and-drop specifically:
- Drag preview position/scale
- External drag source/hover index
- Batch selection state

LaunchpadView becomes a pure declarative view that reads from view models and renders.

### Files
- **New:** `ViewModels/LaunchpadViewModel.swift`
- **New:** `ViewModels/DragDropViewModel.swift`
- **Modified:** `LaunchpadView.swift` — slim, declarative

### Testing
- Unit test `LaunchpadViewModel` with mock AppStore
- Test pagination logic in isolation
- Test drag state management

---

## 2.3 Split SettingsView

### Problem
`SettingsView.swift` is 5733 lines with 14 settings sections all in one file. Each section is 200-600 lines. The file is difficult to navigate and merge-conflict-prone.

### Approach

Extract each section into its own SwiftUI view file:

| Section File | Content | Approx Lines |
|-------------|---------|-------------|
| `GeneralSettingsSection.swift` | Start on login, quit behavior | ~300 |
| `AppearanceSettingsSection.swift` | Icon size, labels, background, colors | ~400 |
| `GridSettingsSection.swift` | Columns, rows, spacing, scroll sensitivity | ~300 |
| `LayoutSettingsSection.swift` | Layout mode, paging/vertical | ~200 |
| `GestureSettingsSection.swift` | Gesture enable, pinch close, tap action | ~200 |
| `HotCornerSettingsSection.swift` | Position, delay, hitbox, toggle | ~200 |
| `SoundSettingsSection.swift` | Sound enable, open/close/navigation sounds | ~200 |
| `ShortcutSettingsSection.swift` | Hotkey capture | ~200 |
| `HiddenAppsSettingsSection.swift` | Hidden apps list with add/remove | ~300 |
| `AppSourceSettingsSection.swift` | Custom app source paths | ~200 |
| `BackupSettingsSection.swift` | Import/export layout | ~300 |
| `AboutSettingsSection.swift` | App info, version, updates | ~300 |

SettingsView becomes a thin container:

```swift
struct SettingsView: View {
    @Environment(AppStore.self) var appStore
    var body: some View {
        ScrollView { LazyVStack(spacing: 20) {
            GeneralSettingsSection()
            AppearanceSettingsSection()
            GridSettingsSection()
            // ...
        }
    }
}
```

### Files
- **New:** `Settings/GeneralSettingsSection.swift` (11 new files total)
- **Modified:** `SettingsView.swift` — thin container

### Testing
- Each section renders correctly
- Navigation between sections works
- Settings persistence still works (UserDefaults)

---

## Phase 2 Exit Criteria
- [ ] AppDelegate < 300 lines
- [ ] LaunchpadView < 500 lines
- [ ] SettingsView is a thin container
- [ ] All coordinators are testable in isolation
- [ ] `docs/00-master-plan.md` updated with completion status
