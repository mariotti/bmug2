# Project: disk size

A planning doc, not a spec. Captures the current shape of the work on
how much space bmug2 is allowed to use and what happens when it grows
too large. Phases are deliberately independent: each is useful on its
own, and later phases can be dropped or reshaped based on what the
earlier ones reveal.

## Status

- **Phase 1 — Measure + report**: **shipped** in #217,
  `v2.18.31-experimental`.
- **Phase 2 — Shell warn-only + per-volume awareness**: **next**.
- **Phases 3–5**: parked (shaped by the policy below, but not
  committed on; shipping Phase 2 should answer most of their open
  questions).

## Core policy: shell warns, GUI acts

A hard split, settled 2026-11-22:

- **Shell (CLI) is read-only + warn-only.** It can measure disk
  usage, carry configuration (budgets, thresholds), and emit
  warnings on every backup run when over budget. It **never**
  deletes data on its own — not behind an `--auto-cleanup` flag,
  not behind an env-var toggle, not even behind a signed
  configuration file. **The only path to deletion from the shell
  is an explicit, human-invoked command** (e.g. the user runs
  `backmeup.archive.sh <project> <days>` with the specific days
  argument that matches what they intend to lose). This is a
  **safety property**, not an inconvenience — automation misfires
  on backup tools lose data, and the shell layer is the one bmug2
  can't recover from if that happens.
- **GUI is the active manager.** It owns the equilibrium between
  SYNC / HISTORY / REMOTE. It can archive old snapshots, suggest
  moves, and (after explicit human confirmation) purge archived
  snapshots past a threshold. It understands that SYNC or HISTORY
  may be on an external volume and treats budgets as **per-volume
  byte counts**, not "total bytes bmug2 uses on this machine".

The shell's "warn" half shipped as a foundation (Phase 2). The GUI's
"act" half is Phase 3+.

### Configuration source of truth

Budgets live in **two layers** (locked in 2026-11-22):

- **Global default** in `backmeup.setup.sh`: new `BMU_SYNC_WARN_BYTES`
  and `BMU_HISTORY_WARN_BYTES` variables, applied to the whole volume
  that SYNC / HISTORY live on. Default: empty (no warning).
- **Per-source override** via a `.bmubudget` sidecar in
  `${BMU_DIRBACKUPS}/<project>/`, same shape as `.bmukind` and
  `.bmureplicate-class`. Format: one `KEY=value` line per key,
  bytes as integers. Overrides the global default for that project.

Both GUI and shell read the same source of truth. The shell writes
the sidecar only via a future `backmeup.budget.sh` helper (not in
Phase 2); the GUI writes the sidecar directly via a Tauri command.

### Volume model

**Per-volume absolute byte budgets**. Each of SYNC, HISTORY, REMOTE
has its own `..._WARN_BYTES` value; actual usage is measured against
the volume the directory lives on (via `df` / `stat -f -t` /
`statfs`). An unplugged external drive doesn't move the budget;
plugging a bigger drive doesn't either. Choosing absolute bytes
over "percent of volume free" avoids the "1% of 4TB" ambiguity.

The GUI's Disk usage view (#217) gains a "Volume: /Volumes/BackupHDD
(2.1TB free of 4.0TB)" subheading per section so the user can see
where each byte lives.

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

## Phase 2 — Shell warn-only + per-volume awareness *(next)*

The foundation of the policy above. **Pure measurement + warning —
no deletion anywhere, no GUI changes.**

Scope:

- **Setup.sh gains two global budget variables** (both optional,
  default empty = no warning):
  - `BMU_SYNC_WARN_BYTES` — soft ceiling on total bytes bmug2's
    SYNC root uses.
  - `BMU_HISTORY_WARN_BYTES` — same, for HISTORY.
- **Per-source override** via `.bmubudget` sidecar in
  `${BMU_DIRBACKUPS}/<project>/`. Supported keys initially:
  `SYNC_WARN_BYTES`, `HISTORY_WARN_BYTES`. Missing / blank = fall
  back to the global default.
- **`backmeup.sh` end-of-run warning**: if the project's current
  SYNC or HISTORY size exceeds its effective budget, print a
  one-line warning naming the project, the overage, and the
  explicit CLI command the user would run to shrink it (e.g.
  `backmeup.archive.sh <project> 180`). Zero behavior change — it
  does not refuse, delay, or skip the backup.
- **`backmeup.disk.sh` JSON gains a `budget` section** and the text
  output an "over budget?" column, so a scripted caller and the
  GUI's Disk usage view can both see the state.
- **Per-volume awareness**: `backmeup.disk.sh` reports **which
  volume** SYNC and HISTORY live on, how much is free on each, and
  flags when they're on the same volume vs different volumes. The
  GUI consumes this (surfaced on the Disk usage screen as a volume
  subheading per section).

**Explicitly out of scope** (defers to Phase 3+):

- Any deletion path.
- A `backmeup.cleanup.sh` or similar new removal command.
- GUI write surface for budgets.
- Remote-side usage (today's "Replicate estimate" is still a local
  proxy; a `rclone size` real-number is a Phase 3 extension).

## Phase 3 — GUI active management *(parked — shape TBD)*

Where the GUI actually acts on the numbers. Candidates:

- **Budget editor** panel inside the Disk usage view: set global
  `SYNC_WARN_BYTES` / `HISTORY_WARN_BYTES`, set per-source overrides,
  saves via a new `set_budget` Tauri command that writes the
  sidecar.
- **One-click archive** for projects visibly over their HISTORY
  budget: dispatches `backmeup.archive.sh <project> <days>` with
  the days picked via a slider, dry-run preview first, then
  explicit "run" confirmation.
- **Suggest moves**: when SYNC is on the system disk and over
  budget, surface a "move this project to an external volume" hint
  — documentation only; actually moving is manual (`rsync -a` +
  path update) with the GUI telling you *what* to do, not *doing*
  it.

The "explicit human confirmation" policy applies: the GUI can
expose a Purge button, but clicking it opens a dry-run preview;
actually running needs a second click on a second screen, same
discipline as the Remove-source "Really remove?" affordance today.

## Phase 4 — Size-reduction primitives *(parked)*

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

## Phase 5 — Last resort: explicit purge *(parked)*

If Phases 2-4 aren't enough on a real machine: an explicit
`backmeup.purge.sh <project> --older-than <days>` command, dry-run
by default. Lists each candidate snapshot with its stamp and size
before anything is removed. **Only path to shell-side deletion**,
per the policy.

The GUI's one-click purge (Phase 3) could call this under the hood.
Shell discipline remains: no deletion without the user typing the
command.

## What's intentionally not in this project

- **Content-addressable dedup** (restic/borg-style). Biggest absolute
  savings but conflicts with the "plain directories" promise —
  restoring needs a tool, not `cp`. Documented in
  `docs/thinning-not-pursued.md`; same mismatch here.
- **Thinning / retention policies** (the reverted #188 plan). Kept
  parked in `thinning-not-pursued.md`. Phase 5's explicit purge is
  the closest we come, and only as a last resort invoked by hand.
- **Auto-cleanup in the shell**. Deliberate — see "Core policy"
  above. Any automation of destruction lives in the GUI, where it
  needs explicit human confirmation and the user is actively
  looking at the consequences.
