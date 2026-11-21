# Project: disk size

A planning doc, not a spec. Captures the current shape of the work on
how much space bmug2 is allowed to use and what happens when it grows
too large. Phases are deliberately independent: each is useful on its
own, and later phases can be dropped or reshaped based on what the
earlier ones reveal.

## Status

- **Phase 1 — Measure + report**: **shipped** in #217,
  `v2.18.31-experimental`.
- **Phases 2–6**: parked, listed below as a living outline (not
  commitments). Decisions to be made; shape may change.

## Phase 1 — Measure + report *(shipped #217, v2.18.31-experimental)*

Foundation. `backmeup.status.sh` already reported KB per project
(`mirror_size_kb` and `history_size_kb` in its JSON output); Phase 1
aggregated that into a cross-project rollup so "how much is bmug2
costing me on this machine?" has a one-line answer.

What shipped:

- New shell command `bin/backmeup.disk.sh` (text + `--json`) — sums
  SYNC + HISTORY across every project and produces a replicate-
  estimate number (local proxy, no remote call: SYNC + HISTORY minus
  any project with `replicate_class=none`).
- New Tauri commands `get_disk_usage` (shells to the new CLI) and
  `get_sources_sizes` (walks each tracked source with `du -sk`;
  size_kb comes back as `None` when a path can't be read).
- New GUI screen `renderDiskUsage` — Settings-style full-screen view
  reached via a "Disk usage" button in the dashboard header. Shows
  four headline numbers (Sources total, SYNC total, HISTORY total,
  Replicate estimate) + per-source and per-project tables.
- Help-icon copy on the Replicate estimate explicitly labels the
  number as a local proxy, not a measurement.

Deliberately out of scope (decisions deferred to later phases):
- No enforcement — report-only.
- No budgets.
- No automatic action on over-size — the user reads the number and
  decides.

## Phase 2 — Budgets (open question)

Configurable size limit, enforced by Phase 3. Open question that
should be resolved **before** writing any code for this phase:

- Per-source budget (`.bmubudget` sidecar under
  `${BMU_DIRBACKUPS}/<project>/`, same shape as `.bmukind` /
  `.bmureplicate-class`)?
- Or a global budget (one line in `backmeup.setup.sh`)?
- Or both (global cap + per-source overrides)?

Arguments for per-source: different projects have wildly different
natural sizes — a 100 MB docs project and a 44 GB media folder
shouldn't share one number. Arguments against: setting N budgets is
more cognitive load than one; users may not want to think about this
per folder.

Arguments for global: matches how users think about free disk space.
Arguments against: a single slowly-growing project under global cap
would eventually squeeze all other projects to zero.

Phase 1's rollup output might make this question answer itself once
real numbers are visible.

## Phase 3 — Warn-only enforcement

`backmeup.sh` logs a warning on each run if the project (or global,
or both) is over budget, with the actionable next step
("`backmeup.archive.sh <project> <days>` to archive old snapshots").
GUI surfaces the same per-source. Never blocks a run — warns only.

Depends on Phase 2's answer.

## Phase 4 — Auto-archive on over-budget

Opt-in `BMU_AUTO_ARCHIVE="yes"` in the project's `.bmuconfig`.
Triggers the existing `backmeup.archive.sh` to compress snapshots
older than N when the budget is exceeded. **No deletion** — matches
bmug2's "transparent directories" promise. Every step reversible.

## Phase 5 — Size-reduction primitives

Revisit hardlinks + zstd *inside* the budget project rather than as
standalone changes:

- **`rsync --link-dest`** for local HISTORY. Auto-detect filesystem
  capability (silently no-op on FAT32/exFAT); off-site replication
  wouldn't preserve the links and keeps paying full size per
  snapshot, which is acceptable because this helps the dusty
  local-HISTORY pile, exactly where the budget issue bites.
- **zstd for archived snapshots**. `backmeup.archive.sh` detects
  `zstd` at run time and falls back to gzip if missing. Same pattern
  `bmuDetectRsync` already uses. `unarchive`/`retrieve` dispatch on
  file extension (`.tar.zst` vs `.tar.gz` vs `.tar`) — already the
  shape we built for `kind=media`'s `.tar`.

Both are policy-driven (budget-aware), not blanket changes.

## Phase 6 — Last resort: deletion of oldest archives

Strict opt-in. Dry-run by default; surfaces each candidate before
running. Reserved for cases where 1–5 isn't enough on a real machine.
If the earlier phases do their job, this phase stays unneeded.

## What's intentionally not in this project

- **Content-addressable dedup** (restic/borg-style). Biggest absolute
  savings but conflicts with the "plain directories" promise —
  restoring needs a tool, not `cp`. Documented in
  `docs/thinning-not-pursued.md`; same mismatch here.
- **Thinning / retention policies** (the reverted #188 plan). Kept
  parked in `thinning-not-pursued.md`. Phase 6's "deletion of oldest
  archives" is the closest we come, and only as a last resort.
