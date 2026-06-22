# LaunchNext — LaunchpadView & Settings rework plan

**Created:** 2026-06-22
**Status:** Draft for user review. NOT for execution until approved.
**Author:** ZCode agent session 2026-06-22, based on user direction + research in `docs/rework-research.md`
**Scope:** Classic/Compact/Hybrid mode split + unified data flow + settings per-mode, with renderer abstraction as a middle-priority workstream. The rework targets **high value, high cost**, with sprinkles of mid.

> This document is the **single source of truth** for the rework. A clean-context agent (likely Claude Code) picking this up should read this end-to-end, plus `docs/rework-research.md` for the evidence base, plus `docs/consolidation-handoff.md` for the current state of the codebase.

---

## Part 1 — History: how the codebase got here

### 1.1 Upstream origin

LaunchNext is a fork of `RoversX/LaunchNext` (originally by IMCSER), an open-source macOS app launcher in the style of macOS Launchpad. The upstream codebase evolved through 2025-09 → 2026-03 with significant feature additions by upstream contributors (RXS / IMCSER / Guilouz / likegravity): multilingual support, dual-mode appearance (fullscreen vs compact), Hot Corners, Dock drag, experimental four-finger gesture support (via the `OpenMultitouchSupport` private framework), uninstall-tool integration, backup/restore, voice feedback, game controller support.

### 1.2 The split point: `8a3b654` (2026-03-14)

Last upstream commit on the local main line:
```
8a3b654 | 2026-03-14 12:18:48 +1100 | RoversX | Revise i18n README translations with updates
```

After this, all 37 commits on local `main` (plus 14 on `develop` from this session) are by you (Vithorio Polten / Hazer). Total: **51 commits of your work** since the split.

### 1.3 Your work arc (the "vision narrative" — non-worktree-organized)

**Phase A (2026-04-03 → 2026-04-05): Feature explosion** — 9 commits, the initial burst of new functionality. All targeting the **classic fullscreen mode** as the primary surface:
- `3856be2` — configurable search strategy (debounce/throttle/instant)
- `5bbf7fa` — registry-based context menu action system (Strategy pattern)
- `0e53b58` — vertical scroll layout mode with native trackpad momentum (4-finger pinch + scroll)
- `8b2fb2a` — top/bottom fade mask in vertical scroll mode
- `d71bd67` — Show in Dock setting
- `141bd20` — Show in Menu Bar setting
- `df6f973` — hide menubar when app visible
- `6b61102` — vertical mode click-to-launch and dismiss-on-background-tap
- `5389a0b` — reliable four-finger pinch gesture with system Launchpad suppression

**Intent at this point**: make the classic fullscreen mode the best version of itself — full-featured, with vertical scroll, modern gestures, dock/menubar integration. You weren't yet thinking about modes as a concept.

**Phase B (2026-04-21 → 2026-04-22): Foundation refactor** — 6 commits:
- `9fe9d34` — **replaced OMS with HIDGestureMonitor** (removed the private framework dependency, switched to public CGEventTap API). Also added F4 interception, batched UserDefaults reads, fixed FSEvents safety, migrated to `@MainActor` AppStore. *This is where the gesture regression crept in* — the rich per-finger `GestureStateMachine` was lost in favor of a simpler scale-ratio detector.
- `a7f8733` + `152e837` — translated all Chinese comments to English
- `b95e2d7` + `952e346` — wrote decomposition design spec
- `ef32008` — **decomposed monolith into 5 Tuist framework targets** (LaunchNextCore, LaunchNextUtilities, LaunchNextInput, LaunchNextStrategies, LaunchNextCLI)

**Intent**: make the codebase maintainable — eliminate private-framework risk, modularize for parallel work, set up for the next round of features.

**Phase C (2026-05-03): SettingsStore extraction + integration** — 13 commits:
- 6 commits (`709ce28` through `067b460`) migrating each view file from `appStore.X` to `appStore.settingsStore.X`
- `5b14d92` — created `SettingsStore` with all settings properties
- `12d1f4c` — integrated SettingsStore + 5 extracted managers (UpdateChecker, OrderPersistence, AppScanner, FolderManager, AppImportService) into AppStore. AppStore shrank from 6,677 → 3,469 lines.
- `2bab7bd` — removed the stale SettingsStore facade
- `0a80823` — fixed all build errors after Phase 2 integration
- `209ad55` + `b138a69` — code review fixes
- `0c927ab` — gitignored Derived directories
- `dad53cc` — merged `feature/phase2-manager-extraction` into main

**Intent at this point**: continue the architectural cleanup — get AppStore down to a manageable size by extracting settings (SettingsStore) and operational managers. This work was largely successful (AppStore halved) but **didn't touch the rendering layer or the mode architecture** — SettingsStore extraction was orthogonal to the LaunchpadView problems.

**Phase D (2026-06-21 → 2026-06-22, this session): Consolidation + research** — 14 commits on `develop`:
- Storage investigation that started as a disk-space cleanup
- Discovered 10 parallel Claude-agent worktrees from Phase C, plus 2 stashes, 2 manual copies, a phase2-manager-extraction branch
- Analyzed via 10 parallel doer agents + 1 orchestrator
- Salvaged unique work (Search/ fuzzy module, release.sh, copy-dir input fixes, CAFolderGridView draft)
- Investigated the gesture regression, ported GestureStateMachine, scaffolded IOHIDTouchProvider
- Researched the architecture for this rework plan

**Where this leaves the codebase**: functional, builds clean, but with **architectural debt** that's blocking further progress — the "wall" you hit. The rework is the response.

### 1.4 The wall

The wall is structural, not feature-driven. You can keep adding features, but each addition fights the architecture:

1. **Mode concepts are scattered** — Classic/Compact binary exists (`AppearanceLayoutMode`) but isn't rigorous. Vertical mode works only through CAGridView's special-case code. Settings aren't gated by mode in the UI.
2. **Two renderer paths** — SwiftUI (paged assumption) and CAGridView (flat items + internal paging/vertical). Adding a feature requires touching both, or accepting that one path is the poor cousin.
3. **Settings bloat** — SettingsView is 5,797 lines. SettingsStore has ~80 properties. As modes multiply, this becomes unmanageable.
4. **Gesture regression** — the system that was supposed to be the *primary* way users invoke LaunchNext (4-finger pinch) is now flaky and feature-poor.

## Part 2 — Critique: what's wrong with the current architecture

(Evidence base: `docs/rework-research.md`.)

### 2.1 Layout/mode enum proliferation

Four enums encoding related concepts with no unification:

| Enum | Location | Cases | Purpose |
|---|---|---|---|
| `LayoutMode` | `LaunchNextStrategies/LayoutStrategy.swift` | `.paged`, `.vertical` | Main-grid scroll strategy |
| `FolderLayoutMode` | `LaunchNext/AppStore.swift` (added this session) | `.paged`, `.vertical` | Folder content grid (used only by draft CAGridView) |
| `AppearanceLayoutMode` | `LaunchNext/AppStore.swift` | `.fullscreen`, `.compact` | **The Classic/Compact split** (colloquially "Classic/Modern"; Compact is the modern-feeling windowed mode) |
| `LayoutModePreviewScope` | `LaunchNext/SettingsView.swift` (private) | mirrors `AppearanceLayoutMode` | UI helper |

**Why this is bad**: "is the main grid paged or vertical?" and "is the app in fullscreen or windowed mode?" are different questions, but they're entangled in code. A new developer (or agent) can't tell from the type system whether changing `LayoutMode.vertical` affects fullscreen only, windowed only, or both. The Hybrid mode you want doesn't have a home — it would need to be a fifth enum or a hack.

### 2.2 Bifurcated data flow

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

**Why this is bad**:
- `makePages` is computed even when unused (drag-preview code references `var pages`)
- Vertical mode **only works via CAGridView**. SwiftUI path can't render vertical because `makePages` always pages
- Adding a third layout (e.g., Hybrid free-form) requires teaching *both* paths about it, or accepting it only works in one
- The renderer choice (`useCAGridRenderer`) is a runtime toggle that bifurcates the entire rendering pipeline

### 2.3 Scattered mode conditionals

9 `isFullscreenMode` checks in `LaunchpadView.swift` alone, each a separate fork:
- Layout sizing (clampedWidth/clampedHeight)
- Padding ratios (top/bottom/side)
- Search bar position
- Dismiss-on-click guards
- Folder popover sizing

**Why this is bad**: there's no single "fullscreen mode" code path — it's scattered. Changing what fullscreen means (e.g., Hybrid's variant) requires hunting down all 9 sites. New mode-related bugs are easy to introduce because the conditionals are independent, not coordinated.

### 2.4 Settings UI doesn't enforce mode split

`SettingsView` (5,797 lines, 13 sections) uses the existing `AppearanceLayoutMode` infrastructure for **storage** (via `scopedX(for:)` accessors and `ModeScopedAppearanceSettings`), but **not for UI**. Both modes' settings appear in the same scrollable form. The user picks a mode in a preview dropdown to edit that mode's values, but every setting is always visible.

**Why this is bad**: users see settings that don't apply to their active mode. Confusing. As Hybrid is added, this gets worse — 3 modes' worth of settings in one form.

### 2.5 Three renderers, no shared abstraction

| Renderer | Role | Lines | Mode-coupling |
|---|---|---|---|
| SwiftUI native (in `LaunchpadView`) | Main grid when `useCAGridRenderer == false` | ~3,600 (whole file) | paged-only |
| `CAGridView` | Main grid when `useCAGridRenderer == true` | 835 | paged + vertical |
| `CAFolderGridView` (draft) | Folder content grid | 1,345 | paged + vertical (not wired) |
| `FolderView` (SwiftUI) | Folder content grid (currently used) | 739 | mode-aware via settings |

**Why this is bad**: CAGridView and CAFolderGridView have ~70% structural similarity but share no code. Each independently computes layout, handles hit-testing, manages selection, renders icons. Adding a feature (e.g., hover magnification tuning) requires touching multiple renderers. The SwiftUI FolderView is a parallel implementation of the same job as CAFolderGridView — pure duplication.

### 2.6 Vertical mode is bolted on

Tracing the code: `LayoutMode.vertical` is consumed only inside `CAGridView` (the renderer). `LaunchpadView.makePages` doesn't know about it. `SettingsStore.layoutMode` is set by the user, but if `useCAGridRenderer` is false, that setting has no effect — the SwiftUI path can't honor it.

**Why this is bad**: a user can have `layoutMode = .vertical` selected in settings, see no effect, and conclude the feature is broken. The toggle's reach depends on another toggle. This is the kind of subtle interaction that erodes trust.

## Part 3 — Proposed architecture

### 3.1 `InterfaceMode` — the unifying concept

Replace the scattered mode logic with a single top-level enum:

```swift
public enum InterfaceMode: String, CaseIterable, Codable, Identifiable {
    case classic    // Fullscreen, fixed horizontal grid, no vertical mode.
                    // This is the Launchpad-classic experience.
                    // ≈ AppearanceLayoutMode.fullscreen + LayoutMode.paged only.
                    // Mostly the upstream LaunchNext experience, minus unrelated fixes.
    
    case compact    // Windowed (Tahoe-like), supports both paged and vertical.
                    // ≈ AppearanceLayoutMode.compact + LayoutMode.{paged, vertical}.
                    // The "modern" windowed UI. Compact name retained from
                    // existing AppearanceLayoutMode.compact — less surprise
                    // for users with existing preferences.
    
    case hybrid     // Fullscreen-first, customizable outer shell, supports
                    // horizontal AND vertical AND future layouts. The home
                    // for evolved classic work with modern features. Gets
                    // the new rendering architecture. References previous
                    // attempts (good and bad) for inspiration but doesn't
                    // duplicate their mistakes. May eventually be more
                    // "modern" than Compact in feel.
    
    var id: String { rawValue }
    
    var supportsVerticalScroll: Bool {
        switch self {
        case .classic: return false
        case .compact, .hybrid: return true
        }
    }
    
    var defaultWindowGeometry: WindowGeometry {
        switch self {
        case .classic, .hybrid: return .fullscreen  // Hybrid is fullscreen-first; customizable later
        case .compact: return .compact
        }
    }
}
```

**Key properties:**
- `classic` is the regression-to-original-Launchpad mode. Horizontal-only. No vertical. Cleanest possible code path. (Per your direction: this is a separate, simpler renderer path, not a feature subset of the current code.)
- `compact` is the current windowed UI (was `.compact` in `AppearanceLayoutMode`, was called "modern" colloquially). Supports vertical (it already did, per upstream's `168f857` commit). Name retained from existing enum to minimize user-facing surprise.
- `hybrid` is the home for your evolved fullscreen-vertical work. Gets the new rendering architecture. **Fullscreen-first** (defaults to `WindowGeometry.fullscreen`) but the outer shell is customizable via `LayoutDescriptor.windowGeometry` — can later support 90%-screen panels, floating windows, etc. without architectural change.

**User-switchable at runtime** (per your direction). Switching modes recomputes `LayoutDescriptor` and triggers re-render. Per-mode `AppearanceStore` + `BehaviorStore` ensure each mode retains its own settings across switches.

**Migration from `AppearanceLayoutMode`:**
- `AppearanceLayoutMode.fullscreen` → ambiguous (was it being used with vertical or not?). Migration script can check `SettingsStore.layoutMode`: if `.vertical` and fullscreen → `.hybrid`; else `.classic`.
- `AppearanceLayoutMode.compact` → `.compact` (drop the "modern" colloquialism in user-facing strings; the enum case stays `.compact`).

### 3.2 `LayoutDescriptor` — the data flow unifier

Replace the bifurcated data flow with a single computed descriptor:

```swift
struct LayoutDescriptor {
    let mode: InterfaceMode
    let scrollStyle: ScrollStyle         // .paged or .vertical (gated by mode.supportsVerticalScroll)
    let windowGeometry: WindowGeometry   // fullscreen / compact / custom — see below
    let columns: Int
    let rows: Int
    let itemsPerPage: Int                // For paged; for vertical, the column count
    let pageSpacing: CGFloat
    // ... appearance-driven fields
}

enum ScrollStyle {
    case paged
    case vertical
}

/// How the LaunchNext window is positioned and sized on screen.
/// Decoupled from InterfaceMode so that any mode can later support
/// non-default geometries (e.g., a 90%-screen Hybrid panel) without
/// architecture changes.
enum WindowGeometry {
    case fullscreen                      // Classic + Hybrid default: cover the whole screen
    case compact                         // Compact default: Tahoe-like windowed
    case custom(rect: CGRect, hasShadow: Bool, cornerRadius: CGFloat)  // Hybrid evolution: configurable outer shell
}
```

**Why `WindowGeometry` is in the descriptor (per Q2 discussion):**
- Hybrid is **fullscreen-first** but its outer shell is customizable. Default = `.fullscreen`. Later R-8b evolution may expose `.custom` — a 90%-screen panel, floating window, etc.
- Putting geometry in the descriptor (not the mode) means Compact isn't architecturally trapped at "small windowed" either — same `.custom` path is available if Compact users ever want a larger variant.
- This avoids re-introducing the "wall" you hit. Locking Hybrid to fullscreen-only would require another architecture change when the floating-panel idea surfaces.

**LaunchpadView computes one `LayoutDescriptor` from `interfaceMode + settingsStore`**. Every consumer (SwiftUI path, CAGridView, CAFolderGridView, Classic renderer) reads from the same descriptor. No more bifurcation.

- `makePages` becomes `func makePages(from: [LaunchpadItem], layout: LayoutDescriptor) -> [[LaunchpadItem]]` — for paged layouts, it chunks. For vertical layouts, it returns a single page (or the renderer ignores pages entirely and reads items directly).
- `LayoutDescriptor` is also the input to the renderer abstraction (see 3.4).

### 3.3 Settings per-mode — `AppearanceStore` + `BehaviorStore`

Apply all three approaches (A+B+C) per your direction:

**Storage (option C, refined):**
- General settings (dock, menubar, hotkeys, gestures, updates, sound, game controller, etc.) remain on `SettingsStore` — global, mode-independent.
- Per-mode settings split into two stores:
  - `AppearanceStore`: icon scale, label font size/weight, folder drop zone scale, page indicator offsets, padding, fade masks, etc.
  - `BehaviorStore`: scroll sensitivity, reverse-wheel-paging, follow-scroll-paging, animation toggles, etc.
- Both stores are **per-`InterfaceMode`**. Storage is `Dictionary<InterfaceMode, AppearanceStore>` (or a 3-case struct for type safety).

**Tagging (option A):**
- Each setting property is tagged with `modes: Set<InterfaceMode>` indicating which modes expose it.
- E.g., `verticalFadeMaskEnabled` is tagged `[.modern, .hybrid]` — hidden in Classic mode.
- SettingsView filters its form by these tags.

**UI split (option B):**
- SettingsView's Appearance section becomes **three sub-sections** (Classic, Compact, Hybrid), showing only the tagged settings for each.
- Master-detail UI: user picks the mode they're configuring; only relevant settings appear.

### 3.4 `GridRenderer` protocol — unify the CA renderers (medium priority)

```swift
protocol GridRenderer {
    var layoutDescriptor: LayoutDescriptor { get set }
    var items: [LaunchpadItem] { get set }
    var appearance: AppearanceStore { get set }
    
    // Callbacks
    var onItemTap: ((LaunchpadItem) -> Void)? { get set }
    var onItemDrag: ((LaunchpadItem, CGPoint) -> Void)? { get set }
    // ... etc.
    
    // Lifecycle
    func update()  // Re-render when inputs change
}
```

Refactor `CAGridView` and `CAFolderGridView` to conform. New renderer additions (e.g., a SwiftUI-native renderer that supports vertical) conform to the same protocol.

**Deferral note:** this is medium priority per your direction. If the per-mode settings + data flow unification deliver most of the user-visible value, the renderer protocol can be a Phase 2 of the rework. Don't block Phase 1 on it.

## Part 4 — Migration path

**Sequencing** (Phase 1 first, defer as indicated):

### Phase R-1: Introduce `InterfaceMode` (foundation)
- Add the `InterfaceMode` enum (3 cases) to `LaunchNextCore`
- Add `SettingsStore.interfaceMode: InterfaceMode` (default: infer from existing `isFullscreenMode` + `layoutMode` at first run)
- Migration: read the user's existing `AppearanceLayoutMode` + `LayoutMode` and infer the new `InterfaceMode` per the table in 3.1
- **Don't yet remove** `AppearanceLayoutMode` or `LayoutMode` — keep both in parallel until all consumers migrate
- Build clean. Existing behavior unchanged.

### Phase R-2: Introduce `LayoutDescriptor`
- Add the `LayoutDescriptor` struct + `ScrollStyle` enum
- Compute it in LaunchpadView from `interfaceMode + settingsStore`
- Pass it to `makePages` (extend the signature)
- **Don't yet** change CAGridView — let it keep reading its existing settings. This phase just adds the descriptor and uses it in the SwiftUI path.
- Build clean. Vertical mode still only works via CAGridView (unchanged).

### Phase R-3: Settings split — `AppearanceStore` + `BehaviorStore` per mode
- Define the two new stores with per-mode storage
- Migrate the existing `ModeScopedAppearanceSettings` fields into `AppearanceStore`
- Add the `modes:` tag to each setting
- Update SettingsView's Appearance section to filter by mode (start with the active `interfaceMode`, then optionally allow editing other modes via a picker)
- **This is the largest single phase** — touches many files but is mostly mechanical (move property, update call sites).
- Build clean. Existing settings still work; users see a reorganized Appearance section.

### Phase R-4: Wire `InterfaceMode` into rendering decisions
- Replace `isFullscreenMode` checks with `interfaceMode.isFullscreen` (or `interfaceMode == .classic` / `.hybrid`)
- Replace `layoutMode == .vertical` checks with `layoutDescriptor.scrollStyle == .vertical` (gated by `interfaceMode.supportsVerticalScroll`)
- CAGridView starts reading from `LayoutDescriptor` instead of `SettingsStore.layoutMode` directly
- **After this phase, the SwiftUI path can render vertical mode** (it just reads `layoutDescriptor.scrollStyle` and lays out accordingly — a single-page vertical layout instead of multi-page horizontal)
- Build clean. Vertical mode now works in both renderers.

### Phase R-5: Classic mode as a separate renderer path
- Per your direction (Q1: "option b, separate simpler code path"): implement Classic mode as its own simpler renderer path. It doesn't need to support vertical, scroll-sensitive layouts, or the modern features. A separate `ClassicGridRenderer` (or just a stripped-down SwiftUI view) for Classic mode only.
- Compact + Hybrid share the unified renderer.
- **Effort tradeoff per user direction**: "retaining some useful changes is good, but it depends on the effort. Some effort may be better spent on hybrid. But some are small enough to be ported and improve classic experience vastly, without changing its original intent." Concretely: port the small high-impact changes (e.g., search-on-Return, the input guards) to Classic since they're trivial and improve the experience. Skip the larger features (vertical, fade masks, etc.) — those would change Classic's intent. **This is a judgment call for the executing agent** — document each decision in the "Decisions made during execution" section.
- **This is where the "wall" gets dismantled** — Classic becomes a clean, simple surface; Compact and Hybrid get the powerful unified path.

### Phase R-6 (deferred, medium priority): `GridRenderer` protocol
- Refactor CAGridView + CAFolderGridView + ClassicGridRenderer to conform to a shared protocol
- Unifies the CA renderer code (~70% structural similarity)
- Can be deferred if R-1 through R-5 deliver the value

### Phase R-7 (parallel): Gesture system restoration
- This is the separate workstream documented in `docs/gesture-handoff.md`
- Implement `IOHIDTouchProvider`, wire `GestureStateMachine` into the active detection path
- Independent of the LaunchpadView rework — can proceed in parallel

### Phase R-8a: Hybrid MvP — fullscreen + vertical + accumulated fixes
- **Scope**: baseline Hybrid = fullscreen mode (default `WindowGeometry.fullscreen`) + vertical scroll support + any small fixes/improvements that didn't land in Classic or Compact during R-1 through R-5.
- This is the minimum that makes Hybrid a real, usable mode — distinct from Classic (which is fullscreen + horizontal only) and Compact (which is windowed + horizontal/vertical).
- **Target outcome**: Hybrid users get the evolved fullscreen-vertical experience you originally built (`0e53b58` and related), now on the new rendering architecture. They can switch to Classic or Compact at runtime and back; settings persist per mode.
- Reference material for what "the evolved experience" means: your Phase A commits (`3856be2` through `5389a0b`), the worktree sources in `docs/worktree-sources/`, and the vertical-scroll implementation on `CAGridView`.

### Phase R-8b (deferred indefinitely): Hybrid Evolution — new features
- **Scope**: brainstorm and plan new features that distinguish Hybrid beyond the MvP baseline. This phase starts only after the rendering architecture (R-1 through R-5) is proven working and flexible.
- **Examples of potential R-8b features** (for brainstorming, not commitment):
  - Customizable outer shell (`WindowGeometry.custom`): 90%-screen panel, floating window, custom corner radius / shadow
  - Free-form layout (not just paged or vertical — e.g., smart grouping, recents shelf, search-results overlay)
  - Advanced gesture mappings (multi-action gestures, mode-specific gestures)
  - Per-display configurations (different Hybrid layouts on different monitors)
- **No urgency.** Hybrid MvP (R-8a) is the user-visible goal. R-8b is the long-term evolution with less pressure, brainstormed once the foundation is solid.

## Part 5 — Handoff prompt for the next agent

> Copy this section into a new Claude Code session as the opening message.

```
You are picking up the LaunchNext LaunchpadView rework. This is a clean-context
session — you have no memory of how the codebase got to its current state.
That's fine; everything you need is in the repo.

## Start here

1. Read this entire file: `docs/launchpad-rework-plan.md`
2. Read the research base: `docs/rework-research.md`
3. Read the current state: `docs/consolidation-handoff.md`
4. Read the gesture handoff (if you'll touch gestures): `docs/gesture-handoff.md`
5. Get the code building:
   cd LaunchNext
   git checkout develop
   tuist generate --no-open
   xcodebuild -workspace LaunchNext.xcworkspace -scheme LaunchNext \
     -configuration Debug -destination 'platform=macOS' build
   Verify: ** BUILD SUCCEEDED **

## What's been done

The consolidation session (2026-06-21 → 2026-06-22) landed these on `develop`:
- Search/ fuzzy module wired into LaunchpadView.filteredItems
- CAFolderGridView draft (NOT wired; reference only for the rework)
- GestureStateMachine ported + IOHIDTouchProvider scaffolded
- copy-dir input fixes (isSetting guards, CAGridView in isInteractiveView)
- Release script (scripts/release.sh)
- Search-on-Return UX (Return with active query opens first match)
- This rework plan + research + gesture handoff

## Your job

Execute the rework plan in Part 4, starting with Phase R-1. Read each phase
carefully before implementing — the plan is prescriptive but not exhaustive;
you'll need to make local decisions. Document those decisions in this file
(append a "Decisions made during execution" section).

**Hard constraints:**
1. NEVER delete work that isn't on `develop`. The worktrees (worktree-agent-*)
   contain reference material. If you need to drop a worktree, first move its
   distinctive content to `docs/worktree-sources/` and tag the branch as
   `archive/pre-rework-YYYY-MM-DD/<name>`.
2. Each phase ends with a clean build (tuist generate + xcodebuild Debug).
   Do not start Phase R-(N+1) until R-N builds.
3. Each phase is its own commit (or small commit series) on `develop`.
   Use conventional commit format: `refactor(rework-RN): ...`.
4. If you hit something the plan doesn't cover, STOP and document the question
   in this file (new section "Open questions during execution") rather than
   guessing.
5. Per-mode settings: use the existing `AppearanceLayoutMode` infrastructure
   as the starting point. The rework EXTENDS it (2 modes → 3, scoped storage
   → per-mode stores), doesn't replace it.

## What NOT to do

- Don't reorganize unrelated code (e.g., don't move Localization while doing
  the settings split). Each phase has a defined scope; respect it.
- Don't add new features during the rework. R-8 is for features; R-1 through
  R-6 are architecture.
- Don't optimize prematurely. The rework is about correctness and clarity,
  not performance.
- Don't drop `LayoutMode` or `AppearanceLayoutMode` until all consumers
  migrate to `InterfaceMode` + `LayoutDescriptor` + `ScrollStyle`. The
  parallel-period is intentional.

## Open questions for the user (resolve before starting Phase R-1)

**These have been answered during plan review (2026-06-22). Preserved as decisions.**

1. **InterfaceMode case naming** — DECIDED: `.classic` / `.compact` / `.hybrid`. The `.compact` name is retained from the existing `AppearanceLayoutMode.compact` to minimize surprise for users with existing preferences. The colloquial "modern" label is dropped from code; user-facing strings can say whatever reads best.
2. **Classic mode's separate renderer path scope** — DECIDED: port small high-impact changes that don't change Classic's intent (e.g., search-on-Return, input guards). Skip larger features. Executing agent uses judgment + documents decisions.
3. **User-switchable at runtime** — DECIDED: yes. Switching modes recomputes `LayoutDescriptor` and triggers re-render. Per-mode settings persist across switches.
4. **Hybrid fullscreen-only vs fullscreen-first customizable** — DECIDED: **fullscreen-first with customizable outer shell.** `LayoutDescriptor.windowGeometry` defaults to `.fullscreen` for Hybrid but supports `.custom(rect, hasShadow, cornerRadius)` for later evolution. Compact also benefits from the same path if it ever wants a larger variant. See Part 3.2 for the `WindowGeometry` enum.
5. **Hybrid distinguishing features beyond fullscreen + vertical** — DECIDED: split into R-8a (MvP: fullscreen + vertical + accumulated fixes) and R-8b (Evolution: new features brainstormed after the architecture is proven). See Part 4 Phases R-8a/R-8b.

## Reference material

- `docs/rework-research.md` — 6-thread research base
- `docs/consolidation-handoff.md` — current state of `develop`
- `docs/gesture-handoff.md` — gesture system handoff (separate workstream)
- `docs/deferred-work-cafolderview-gesture.md` — CAFolderGridView framing
- `docs/worktree-sources/` — reference snapshots from consolidated worktrees
- `docs/spec-synthesis.md` — original spec synthesis (note: contains errors
  corrected by later doer analysis; trust the consolidation-handoff over this)
```

## Part 6 — Decisions made during execution

(To be filled in by the executing agent.)

## Part 7 — Open questions during execution

(To be filled in by the executing agent.)

---

## Appendix A — File map (what lives where after the rework)

| Area | Current location | Post-rework location | Phase |
|---|---|---|---|
| `InterfaceMode` enum | (doesn't exist) | `LaunchNextCore/InterfaceMode.swift` | R-1 |
| `LayoutDescriptor`, `ScrollStyle`, `WindowGeometry` | (doesn't exist) | `LaunchNextStrategies/LayoutDescriptor.swift` | R-2 |
| `AppearanceStore` per mode | (in `SettingsStore`, scattered) | `LaunchNext/Appearance/AppearanceStore.swift` | R-3 |
| `BehaviorStore` per mode | (in `SettingsStore`, scattered) | `LaunchNext/Appearance/BehaviorStore.swift` | R-3 |
| Classic renderer path | (doesn't exist; fork inside current LaunchpadView) | `LaunchNext/Renderers/ClassicGridRenderer.swift` | R-5 |
| Compact/Hybrid renderer path | `LaunchNext/CAGridView.swift` + SwiftUI path | `LaunchNext/Renderers/UnifiedGridRenderer.swift` (shared) | R-4, R-5 |
| `GridRenderer` protocol | (doesn't exist) | `LaunchNextStrategies/GridRenderer.swift` | R-6 (deferred) |
| Gesture state machine | `LaunchNextInput/Gesture/GestureStateMachine.swift` (scaffolded) | same location (production impl) | R-7 (parallel) |

## Appendix B — What gets removed (after migration complete)

- `AppearanceLayoutMode` (replaced by `InterfaceMode`)
- `LayoutModePreviewScope` (private UI helper, replaced by InterfaceMode picker)
- `FolderLayoutMode` (the one added in consolidation; either merged into `ScrollStyle` or removed if CAGridGridView draft is dropped)
- The 9 scattered `isFullscreenMode` checks (replaced by `interfaceMode.isFullscreen` or `LayoutDescriptor`)
- `makePages` in its current form (replaced by `LayoutDescriptor`-aware version)
- The `useCAGridRenderer` toggle (replaced by `InterfaceMode` determining the renderer path)

**Note:** removal happens in late phases (R-4 or later), after all consumers migrate. Don't remove during the parallel-period.
