# LaunchpadView rework — research notes

**Created:** 2026-06-22
**Status:** in-progress research feeding into `docs/launchpad-rework-plan.md` (to be written)
**Purpose:** evidence-grounded critique of current architecture to inform the rework plan. Each section is a research thread with findings.

## Thread 1: Layout/mode enum proliferation

There are **four distinct layout/mode enums** in the codebase, partially overlapping in concept but not unified:

| Enum | Location | Cases | Purpose |
|---|---|---|---|
| `LayoutMode` | `LaunchNextStrategies/LayoutStrategy.swift` | `.paged`, `.vertical` | Main grid scroll strategy (paged horizontal vs vertical scroll). Used by `CAGridView`, `SettingsStore.layoutMode`. |
| `FolderLayoutMode` | `LaunchNext/AppStore.swift` (I added this in consolidation) | `.paged`, `.vertical` | Folder content grid layout. Used only by `CAFolderGridView` (which is a draft, not wired). |
| `AppearanceLayoutMode` | `LaunchNext/AppStore.swift` | `.fullscreen`, `.compact` | **The Classic vs Modern split.** Used by `ModeScopedAppearanceSettings` to hold separate appearance settings per mode. |
| `LayoutModePreviewScope` | `LaunchNext/SettingsView.swift` (private) | (mirrors AppearanceLayoutMode) | UI helper for the appearance-settings preview picker. |

**The "rigid and hacky" smell:** these enums encode related but distinct concepts that aren't related to each other in code:
- `AppearanceLayoutMode.fullscreen` ≈ Classic mode (your framing)
- `AppearanceLayoutMode.compact` ≈ Modern mode (windowed)
- `LayoutMode.vertical` is an option *within* either mode
- `FolderLayoutMode` is a parallel concept for the folder grid
- The proposed Hybrid mode is a *third* `AppearanceLayoutMode` that doesn't exist yet

**The rework opportunity:** unify these into a coherent mode hierarchy:
- A top-level `InterfaceMode` enum: `.classic`, `.modern`, `.hybrid` (your Classic/Modern/Hybrid split — extends `AppearanceLayoutMode` from 2 to 3 cases + renames for clarity)
- A `LayoutStyle` enum (paged vs vertical) *nested under* each `InterfaceMode`, expressing which layouts each mode supports (Classic = paged only, Modern = paged + vertical, Hybrid = paged + vertical + extras)
- One canonical location for the active mode (`SettingsStore.interfaceMode`), replacing the scattered `isFullscreenMode` checks

### Conditional density (LaunchpadView.swift)

| Condition | Count | Notes |
|---|---|---|
| `isFullscreenMode` | 9 | Scattered — affects layout, sizing, padding, dismiss behavior, search bar position. Each is a separate fork; no shared "fullscreen mode" code path. |
| `isVerticalMode` | 0 | None in LaunchpadView directly — the vertical-mode logic is in CAGridView (the rendering layer), not the SwiftUI view layer. |
| `layoutMode` | 1 | Single reference — LaunchpadView mostly delegates layout to the renderer. |

**Finding:** the SwiftUI layer (LaunchpadView) is *moderately* mode-aware (9 `isFullscreenMode` forks) but the heavy mode-coupling is in CAGridView (the Core Animation renderer). The rework should evaluate whether these 9 forks are cohesive enough to extract into a per-mode view subtree, or whether they're scattered one-offs that should just be properties on a `LayoutContext`.

## Thread 2: `AppearanceLayoutMode` and `DualModeAppearanceSettings` — the existing Classic/Modern infrastructure

This is the most important finding so far. Main already has the infrastructure for "different settings per mode":

```swift
enum AppearanceLayoutMode: String, CaseIterable, Codable, Identifiable {
    case fullscreen  // ≈ Classic
    case compact     // ≈ Modern
}

struct ModeScopedAppearanceSettings: Codable, Equatable {
    var iconScale: Double
    var iconLabelFontSize: Double
    var folderDropZoneScale: Double
    var pageIndicatorOffset: Double
    var pageIndicatorTopPadding: Double
    var pageIndicatorPerDisplayEnabled: Bool
    var pageIndicatorOverrides: [String: PageIndicatorOverride]
}

struct DualModeAppearanceSettings: Codable, Equatable {
    var fullscreen: ModeScopedAppearanceSettings
    var compact: ModeScopedAppearanceSettings
}
```

`AppStore` exposes `scopedX(for: AppearanceLayoutMode)` accessors that read/write the per-mode slot. `SettingsView` uses `selectedAppearanceLayoutMode` to scope its UI to the currently-edited mode.

**This means**: the user's proposal (Classic/Modern/Hybrid, with per-mode AppearanceStore + BehaviorStore) is **a generalization of existing architecture**, not a greenfield design. The rework extends:
- 2 modes → 3 (add `.hybrid`)
- 6 scoped appearance properties → full AppearanceStore + BehaviorStore per mode
- Generalize `DualModeAppearanceSettings` → `PerModeAppearanceSettings` (Dictionary or 3-case struct)

This is **much** smaller than I initially feared. The pattern is established; it just needs to be applied consistently and extended.

## Thread 3: AppStore state flow — bifurcated by renderer

**Data flow tracing:**

```
AppStore.items (flat [LaunchpadItem])
    ↓
LaunchpadView.filteredItems (search engine output)
    ↓
    ├─ SwiftUI path (when useCAGridRenderer == false):
    │     → makePages(from: filteredItems) — chunks by config.itemsPerPage
    │     → ForEach over [[LaunchpadItem]] (paged assumption baked in)
    │
    └─ CAGridView path (when useCAGridRenderer == true):
          → CAGridViewRepresentable passes `items: [LaunchpadItem]` directly
          → CAGridView does its OWN paging (or vertical-scroll layout) internally
          → `makePages` is bypassed entirely
```

**The architectural problem:**
1. **Two data flow paths** for the same logical job (render the app grid). The SwiftUI path assumes paging; the CAGridView path doesn't.
2. `makePages` in LaunchpadView is dead code when CAGridView is active — but it's still computed (wasted work) because `var pages` is referenced by `visualItems` which is referenced by drag-preview logic.
3. **Vertical mode only works via CAGridView.** The SwiftUI path can't render vertical mode because `makePages` always pages by `itemsPerPage`. So vertical-mode users are forced onto the CAGridView path.
4. `config.itemsPerPage` is `columns × rows` — assumed everywhere. If a future layout (e.g., Hybrid's free-form) doesn't fit rows × cols, this breaks.

**Implication for rework:** the data flow should be **mode-aware at the LaunchpadView level**, not bifurcated at the renderer level. A `LayoutDescriptor` (computed from `interfaceMode` + `layoutStyle`) should produce either pages or a flat list, and both SwiftUI and CA renderers should consume that unified shape.

## Thread 4: LaunchpadView structure — 9 `isFullscreenMode` sites

The 9 forks aren't cohesive enough to extract as a per-mode subtree. They're scattered one-offs affecting:
- Layout sizing (clampedWidth/clampedHeight differ)
- Padding (top/bottom/side padding ratios)
- Search bar position
- Dismiss-on-click guards
- Folder popover sizing

**Implication for rework:** don't try to extract per-mode view subtrees. Instead, introduce a `LayoutContext` struct computed once per mode switch, holding all the mode-dependent values (paddings, sizes, positions). LaunchpadView reads from `LayoutContext` instead of checking `isFullscreenMode` inline.

## Thread 5: SettingsView — 5,797 lines, scoping exists but isn't enforced as a UI split

**Structure:**
- 13 sections (general, appearance, performance, titles, appSources, hiddenApps, uninstall, shortcuts, backup, development, sound, gameController, updates, about)
- Master-detail UI (`List(selection: $selectedSection)` + `detailView(for:)`)
- Appearance section already uses `selectedAppearanceLayoutMode` (fullscreen/compact) for **scoped storage** but **not for scoped UI** — both modes' settings appear in the same scrollable form, with the scoping being implicit (the user picks a mode in a preview dropdown to edit that mode's values).

**The user's complaint:** "settings for a mode shouldn't appear when the other is active." Main's current UI shows all settings; the mode picker only affects which slot gets written. This is confusing.

**Implication for rework:** the per-mode UI split is straightforward given the existing `selectedAppearanceLayoutMode` infrastructure. Concretely:
- Add `.hybrid` as a third `AppearanceLayoutMode` case
- For each setting, tag it with `modes: Set<InterfaceMode>` (your "option A" — property-level filtering)
- SettingsView's `appearanceSection` becomes three sub-sections (Classic, Modern, Hybrid), each showing only its tagged settings
- Optionally: separate `AppearanceStore` + `BehaviorStore` per mode (your "option C") for the scoped storage, replacing the current `ModeScopedAppearanceSettings` struct

## Thread 6: Renderer split — no shared abstraction

**Three renderers exist:**
1. **SwiftUI native** (`LaunchpadView.swift` body — `ForEach` over pages, `LazyVStack` of items)
2. **CAGridView** (`LaunchNext/CAGridView.swift` — Core Animation NSView, used when `useCAGridRenderer == true`)
3. **CAFolderGridView** (the draft I added — Core Animation NSView for folder content, not wired)

Plus **FolderView** (`LaunchNext/FolderView.swift`, 739 lines, SwiftUI native) for the folder-open view.

**Shared abstraction:** NONE. Each renderer independently:
- Computes layout (columns, rows, spacing, padding)
- Handles hit-testing (click, drag, hover)
- Manages selection state
- Renders icons + labels

CAGridView and CAFolderGridView have ~70% structural similarity (both are CA NSViews doing paged/vertical grids) but no shared base class or protocol.

**Implication for rework:** a `GridRenderer` protocol (or abstract base) would unify the CA renderers and clarify the contract with SwiftUI. The rework should:
1. Define `GridRenderer` protocol (inputs: items, layout descriptor, appearance settings, callbacks; outputs: rendered NSView)
2. Refactor CAGridView + CAFolderGridView to conform
3. Define a `SwiftUIGridRenderer` that conforms via SwiftUI (or accept that SwiftUI is fundamentally different and document the bifurcation)

This is **significant work** — likely the largest single piece of the rework. May be worth deferring if the per-mode settings split + data flow unification deliver most of the value.

## Summary of architectural problems (for the rework plan)

1. **Layout/mode enum proliferation** (4 enums, partially overlapping, no unification)
2. **Bifurcated data flow** (SwiftUI paged path vs CAGridView flat-items path; `makePages` assumes paging)
3. **Scattered mode conditionals** (9 `isFullscreenMode` sites in LaunchpadView, no shared context)
4. **Settings UI doesn't enforce mode split** (infrastructure exists, UI doesn't use it)
5. **No renderer abstraction** (3 renderers, no shared protocol)
6. **Vestigial/duplicated state** (e.g., `FolderLayoutMode` I added vs `LayoutMode` — same concept, separate enums; both paged/vertical)
7. **Vertical mode bolted on** (only works via CAGridView; SwiftUI path can't do it; `makePages` doesn't know about it)

The rework plan should prioritize these by user-visible value vs implementation cost. My instinct:
- **High value, moderate cost**: per-mode settings split (Classic/Modern/Hybrid) — extends existing `AppearanceLayoutMode` infrastructure
- **High value, high cost**: unified data flow (LayoutDescriptor + mode-aware pagination)
- **Medium value, high cost**: renderer abstraction (`GridRenderer` protocol)
- **Low value, low cost**: enum cleanup (collapse the 4 layout enums into a coherent hierarchy)

