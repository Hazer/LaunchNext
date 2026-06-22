# docs/worktree-sources/

Reference snapshots of source files from the consolidated worktrees, preserved
here so they survive worktree deletion. These are **reference material for the
LaunchpadView rework**, not code to be compiled or wired as-is.

Each file is named `<OriginalName>.<worktree-name>-<short-purpose>.swift` so the
provenance is unambiguous.

## Current contents

### `LaunchpadView.af967f48-search-on-return.swift`
- **Source**: `worktree-agent-af967f48/LaunchNext/LaunchpadView.swift` (HEAD `a68c5c9`)
- **Why preserved**: contains the search-on-Return UX logic (Return with active
  query → open first/selected match). This has been ported to `develop` as a
  clean additive feature, but the full file is kept here as reference for the
  rework — it shows the surrounding keyboard-navigation code in context, which
  the rework plan should consult when restructuring keyboard handling.
- **Status of the ported logic**: landed on `develop`, search-on-Return block
  at the `code == 36` handler in `LaunchNext/LaunchpadView.swift`.
- **What's NOT ported from this file** (intentionally): the pre-SettingsStore-
  extraction `appStore.X` references (regressions), the `AppStore.default
  ScrollSensitivity` usages (moved to `SettingsStore`).

## Adding more files here

As the rework research identifies additional worktree content worth preserving
as reference, copy it here with the same naming convention. Add an entry to
this README explaining what it is and why it's preserved.

**Do not** copy entire worktrees here — only distinctive files that have value
as reference and aren't already on `develop`. Files that landed on `develop`
don't need to be here (they're in the live codebase).

## Relationship to the rework plan

The rework plan (`docs/launchpad-rework-plan.md`, to be written) will cite
these files where relevant — e.g., "the new Modern mode keyboard handler
should preserve the search-on-Return UX from
`docs/worktree-sources/LaunchpadView.af967f48-search-on-return.swift` lines
2140-2160".
