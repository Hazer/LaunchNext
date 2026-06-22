# LaunchNext — Post-Consolidation Handoff

**Created:** 2026-06-21 (end of consolidation session)
**Audience:** any future agent (or developer) picking up LaunchNext work
**Source session:** storage investigation → multi-agent worktree analysis → consolidation on local `develop` branch

> This document is the single source of truth for the state of LaunchNext as of 2026-06-21 end-of-day. A fresh agent reading only this file + the linked docs should be able to resume work without losing context.

---

## TL;DR

LaunchNext is a macOS app launcher (fork of `RoversX/LaunchNext`). A multi-week refactor effort left 10 parallel Claude-agent worktrees, 2 stashes, 2 manual `LaunchNext copy` dirs, and an unmerged `feature/phase2-manager-extraction` branch — most holding overlapping attempts at the same features. A consolidation session on 2026-06-21 (this one) analyzed every artifact via parallel doer agents, then landed the genuinely unique salvageable work on a new local `develop` branch (8 commits, builds clean). Most worktree content was already on `main` (via your own commits like `0e53b58`) or recoverable from `upstream/main`.

The 10 worktrees, 1 remaining stash (`stash@{1}`), 2 copies, and `feature/phase2-manager-extraction` situation are **untouched** pending your review of `develop`. Only the genuinely safe items were dropped: `stash@{0}` (accidental), the zip backup, and the fully-merged phase2 branch + worktree.

---

## 1. Where the project stands right now

### Branches

| Branch | HEAD | Purpose | Build |
|---|---|---|---|
| `main` | `dad53cc` "Merge branch 'feature/phase2-manager-extraction'" | Pre-consolidation baseline. 37 commits ahead of `origin/main` (your fork `Hazer/LaunchNext`), 23 commits behind `upstream/main` (`RoversX/LaunchNext`). **Not pushed.** | Builds (was the consolidation baseline) |
| `develop` (NEW) | `82e1aaa` | Consolidation result — salvage + CAFolderGridView port. 8 commits ahead of main. | **BUILD SUCCEEDED** (verified via `tuist generate` + `xcodebuild Debug`) |
| `worktree-agent-*` (×10) | various | Original Claude agent worktrees from 2026-05-03 parallel refactor attempt. **All still present**, locked. | n/a |
| `feature/phase2-manager-extraction` | DELETED 2026-06-21 | Was fully merged to main as `dad53cc`. | n/a |

### Remotes

```
origin    git@github.com:Hazer/LaunchNext.git   (your fork; currently tracks upstream HEAD, has none of your local work)
upstream  git@github.com:RoversX/LaunchNext.git (source of fork)
```

**Restructured during this session** (Proposal F): `origin` was renamed to `upstream`, then `Hazer/LaunchNext` added as new `origin`. Push to origin pending (see §5).

### Worktrees (all still present)

```
/Users/hazer/Projects/BrowserOSProjects/LaunchNext                                   c1ff4a9 [develop]   ← you are here
/Users/hazer/Projects/BrowserOSProjects/LaunchNext/.claude/worktrees/agent-a090fa62  19d5381 [worktree-agent-a090fa62] locked
/Users/hazer/Projects/BrowserOSProjects/LaunchNext/.claude/worktrees/agent-a5ef3716  726fafb [worktree-agent-a5ef3716] locked
... (8 more, all locked)
```

### Stashes

```
stash@{0}: On main: perfect    ← YOUR 2026-04-03 23:37 vertical-scroll design snapshot. Content is byte-identical to commit 0e53b58 (your own commit, 9 minutes later) + 9 ContextMenu/Strategy files that are on main. Preserved as design history; your call whether to drop.
```

### Manual copies (untouched)

- `BrowserOSProjects/LaunchNext copy` (107M, 1 dirty file: `LaunchpadApp.swift` — click-outside-to-close)
- `BrowserOSProjects/LaunchNext copy 2` (107M, 3 dirty files: `CAGridView+Input.swift`, `LaunchpadApp.swift`, `LaunchpadView.swift`)

Both at `df6f973` (ancestor of main). Dirty content has been **ported to develop** (commit `69892ca`); the copies themselves remain for your review.

---

## 2. What `develop` contains (the consolidation result)

Eight commits on top of `main`:

```
82e1aaa docs: update deferred-work — Proposal C ported, Proposal E dropped
f92125a feat(folder-grid): add CAFolderGridView (CA renderer for folder content)
c1ff4a9 docs: deferred-work plan for CAFolderGridView + GestureInputDevice integration
e6cdd25 fix(search): add import LaunchNextCore to LaunchpadSearchEngine
69892ca fix(input): suppress background-dismiss while settings open + extend to CAGridView
c8ea9b5 build: add scripts/release.sh for local release packaging
3b9fe2d feat(search): wire LaunchpadSearchEngine into filteredItems
c8e92f5 chore: untrack Derived/ and DerivedDataTuist/ build artifacts
```

### Landed changes

**Search (Proposal B)** — `3b9fe2d` + `e6cdd25`:
- Added `LaunchNext/Search/{FuzzyMatcher,LaunchpadSearchEngine,SearchIndexEntry}.swift` (ranked fuzzy matching with acronym/subsequence/token-prefix scoring, diacritic+case+width-insensitive normalization)
- `LaunchpadView.filteredItems` now calls `searchEngine.filter(items:query:fuzzyEnabled:)` instead of `localizedCaseInsensitiveContains` substring loop
- Added `SettingsStore.fuzzySearchEnabled` (@Published Bool, defaults true) so users can disable fuzzy and fall back to substring

**Folder grid (Proposal C, partial)** — `f92125a`:
- Added `LaunchNext/CAFolderGridView.swift` (1,345 lines) + `CAFolderGridViewRepresentable.swift` (133 lines) — Core Animation folder content renderer with paged + vertical layouts, hover magnification, drag reorder
- Added `AppStore.FolderLayoutMode` enum + `SettingsStore.folderLayoutMode` property
- Added `AppStore.copyAppPath(_:)`, `showAppInFinder(_:)`, `reorderAppInFolder(folderID:from:to:)` methods
- Added `FolderManager.reorderAppInFolder(folderID:from:to:)` (proper delegate-based persistence)
- **Not yet wired**: `LaunchpadView` still uses SwiftUI `FolderView` at line 673. A `useCAGridFolderRenderer` toggle + page-state bindings wiring is the remaining follow-up (small).

**Release script (Proposal D)** — `c8ea9b5`:
- Added `scripts/release.sh` (self-contained bash: xcodebuild Release arm64+x86_64, packages app + checksums)
- **Intentionally NOT added**: `.github/workflows/update-homebrew.yml` (hardcoded to `RoversX/homebrew-tap` upstream; would need updating to your own tap if fork-distributed)

**Input fixes (Proposal H)** — `69892ca`:
- Added `BorderlessWindow.sendEvent` override (catches clicks that escape SwiftUI hit-testing on CA sublayers)
- Added `CAGridView` to `isInteractiveView` type check (both `BorderlessWindow` and `AppDelegate` helpers)
- Added `!appStore.isSetting` guard to `handleBackgroundClick` and all 5 `onTapGesture { hideWindow() }` blocks (suppress dismiss while settings sheet is open)
- Wired `CAGridView+Input.swift` empty-area branch: vertical-mode clicks now route through `onEmptyAreaClicked?()` (paged keeps page-drag behavior)

**Chore** — `c8e92f5`:
- Untracked 3,891 `Derived/` + `DerivedDataTuist/` files that were committed in repo history (regenerable build artifacts, already in `.gitignore`)

### Deferred / dropped (see `docs/deferred-work-cafolderview-gesture.md` for details)

| Item | Disposition | Reason |
|---|---|---|
| Proposal A (vertical scroll from stash@{1}) | No-op | Already on main via your own commit `0e53b58` (2026-04-03 23:46, 9 minutes after the stash). Verified byte-identical. |
| Proposal E (GestureInputDevice.swift) | Dropped | References `OMSDeviceInfo` which was removed when OMS was replaced by HIDGestureMonitor. HIDGestureMonitor uses a system-wide CGEventTap with no per-device filtering — the abstraction has no consumer. |
| LaunchpadView CAGridView toggle wiring | Pending follow-up | Component is on develop and compiles; only the toggle + bindings remain. |

---

## 3. What's still on the worktrees (and why they're preserved)

The 10 worktrees were **not dropped** during this session per your instruction. The doer-agent analysis (in `docs/consolidation-proposal.md`) characterized each — but per your correction mid-session, "exists elsewhere" does NOT mean "safe to drop." The worktrees contain your work; some of it is the origin of code that later landed on main/upstream.

**Key worktrees to know about:**
- `worktree-agent-af967f48` and `worktree-agent-afad21ec` — held the canonical source for Search/ module + CAFolderGridView + (afad21ec only) Homebrew release infra. These have now been **ported to develop**. The worktrees themselves remain.
- `worktree-agent-a78a93dc` (738M, the largest) — integration worker state, content also on main.
- Others — various parallel attempts at SettingsStore migration / manager extraction, mostly superseded by main.

**stash@{1}** "On main: perfect" — your 2026-04-03 vertical-scroll design. Content on main via `0e53b58`. Preserved as named design history; drop is your call.

---

## 4. Open follow-ups (in priority order)

1. **Review `develop` yourself** — build it, run it, eyeball the diffs (especially the input behavior changes from Proposal H). This is the gate for everything else.
2. **Wire CAFolderGridView into LaunchpadView** (small) — add `useCAGridFolderRenderer` toggle to SettingsStore + switch between FolderView/CAFolderGridViewRepresentable at line 673. Page-state bindings need `@State` on LaunchpadView.
3. **Decide worktree dispositions** — once you've reviewed develop and are confident nothing was lost, work through the 10 worktrees + 2 copies + stash@{1} one by one. Doer analysis is in `docs/consolidation-proposal.md` §1. Create archive tags before any deletion.
4. **Push develop to `Hazer/LaunchNext`** — `git push -u origin develop` (your fork is at upstream HEAD; push will fast-forward).
5. **Merge `upstream/main` into develop** — 23 upstream commits with real features (Italian + Traditional Chinese localizations, "Show all input devices" gesture option, fuzzy search, CAGridView folder grid, Homebrew, `reverseWheelPagingDirection` vertical fix). Real conflict work — separate session. Note: much of what upstream has, you independently wrote and is now also on develop (Search/, CAGridView folder) — merge will need reconciliation.
6. **Repo hygiene**: 19 Xcode project files (`LaunchNext.xcodeproj/*`, `LaunchNext.xcworkspace/*`) are tracked but tuist-regenerated on every `tuist generate`. They should be untracked + gitignored, but that's an upstream-repo hygiene issue — coordinate via PR if you contribute back, or just untrack on your fork.

---

## 5. Recovery / safety nets

- **`develop` branch**: 8 commits, all build-verified. Recoverable via `git checkout develop`.
- **`main` branch**: unchanged from pre-consolidation (`dad53cc`). `develop` is strictly additive.
- **`upstream/main`** (`RoversX/LaunchNext`): 23 commits ahead of your local main. Hasn't been touched.
- **`origin/main`** (`Hazer/LaunchNext`): your fork, currently at upstream HEAD (`328a5e9`). No local work has been pushed.
- **Worktrees (10)**: all intact, all locked. Per doer reports, none hold unique unmergeable work that isn't either on main, upstream, or now develop.
- **`stash@{1}`**: preserved.
- **Archive tags**: not created yet (postpone until worktree-disposition decisions are made — see follow-up #3).
- **This session's logs and analysis**: in `~/storage-investigation/` (snapshots, plans, doer outputs, consolidation proposal, deferred-work doc).

## 6. If you're a new agent picking this up

1. Read this doc end-to-end.
2. Read `docs/consolidation-proposal.md` for the per-worktree analysis.
3. Read `docs/deferred-work-cafolderview-gesture.md` for what's pending.
4. `cd LaunchNext && git checkout develop && tuist generate --no-open && xcodebuild -workspace LaunchNext.xcworkspace -scheme LaunchNext -configuration Debug -destination 'platform=macOS' build` — verify the baseline builds for you.
5. `git log --oneline main..develop` — see what consolidation added.
6. If anything in this doc contradicts what you see, trust the git state and update this doc.
7. Before any destructive op, propose it in a new section below and wait for explicit user approval.

## 7. Pending destructive ops (NONE approved yet)

The following have been **analyzed** but **not approved** for execution. Do not run without explicit per-item user sign-off:

- Drop any of the 10 `worktree-agent-*` worktrees
- Drop `stash@{1}`
- Drop `LaunchNext copy` or `LaunchNext copy 2`
- Push `develop` or `main` to `origin` (`Hazer/LaunchNext`)
- Merge `upstream/main` into `develop`
- Untrack the 19 Xcode project files
- Delete any worktree branch (even after `git worktree remove`)
