# Plan: snapshot thinning (`backmeup.thin.sh`) — NOT PURSUED

> **Status: not pursued (decided 2026-11-02).**
>
> This plan was partially implemented (PR #188) and then reverted (PR
> #189) after design review. The content below is kept **as a record
> of a path considered and rejected**, not as a specification to
> implement. Don't start building this.
>
> **Why it was dropped.** bmug2's identity is "snapshots are plain
> inspectable directories; `archive.sh` compresses but never
> deletes." A user can recover from any `B-<stamp>` or any `.tar.gz`
> by hand, with no bmug2 code present. The fold-merge model in
> section 2 below changes what a `B-<stamp>` *means* — no longer
> "the versions replaced at timestamp T", but "the oldest version
> replaced between the previous kept snapshot and T". The plan
> itself called this out ("Document the resulting semantics in the
> manual." in section 2) — a tell that we were trading away
> transparency for a storage saving that isn't acute for the
> project's typical workload (text-heavy thesis-style projects at
> 30-min cadence stay comfortably under a few GB over a year).
>
> **If storage ever becomes acute** for users with large binary
> files, the honest answer is **chunk-level content-addressable
> deduplication** (borg / restic style), not thinning — a different
> architecture, not a stepping stone from this path. bmug2 stores
> **full-file copies** in each `B-<stamp>` (via `rsync -av --delete
> --backup`), not diffs; even a lossless "keep every file version"
> variant of thinning (model C in the discussion) would dedupe only
> at whole-file granularity, which is a modest win for frequently
> edited files. Chunked dedup is where the real storage saving
> lives, and it belongs on its own roadmap.
>
> **What did land from the surrounding discussion:**
>
> - **PR #184** — `archive.sh` / `unarchive.sh` take the per-project
>   `.bmulock`. Was side finding #1 at the bottom of this doc.
> - **PR #186** — `build_housekeeping_wrapper` runs `replicate.sh`
>   for the `local` backend too. Was side finding #2 at the bottom
>   of this doc.
>
> Both side findings were legitimate bug fixes unrelated to the
> thinning feature itself.
>
> ---
>
> The original plan follows, unchanged.

# Plan: snapshot thinning (`backmeup.thin.sh`)

Adds the missing retention step. Today bmug2 never removes a snapshot:
`archive.sh` only compresses. This plan adds **time-bucket thinning**
(borg `prune` / restic `forget` style) with a **fold-merge** mechanism
that is correct for bmug2's delta snapshots.

Verified on `main` (7ffe5b3): no prune/thin/evict/retain logic exists
anywhere in `bin/`.

## 1. Behaviour

- **Opt-in.** All `KEEP_*` variables empty → thinning disabled, script
  prints "thinning disabled" and exits 0. Existing installs see no
  change.
- **Policy** (each empty = rule off; `all` allowed for yearly):

  ```sh
  BMU_KEEP_HOURLY=""     # newest snapshot per hour, for the last N hours that have one
  BMU_KEEP_DAILY=""
  BMU_KEEP_WEEKLY=""
  BMU_KEEP_MONTHLY=""
  BMU_KEEP_YEARLY=""     # number or "all"
  BMU_KEEP_MIN="3"       # never go below this many snapshots
  ```

- **Keep set** = union over all rules. For each rule, walk snapshots
  newest → oldest; keep the newest snapshot of each bucket until N
  buckets are filled. The newest snapshot overall is always kept.
- **Dropped snapshots** that have a newer kept snapshot → **fold-merge**
  into it (section 2).
- **Tail** (snapshots older than the oldest kept one) → plain delete.
  Safe: they only hold versions from before the oldest restore point.
- `BMU_KEEP_MIN` is a hard floor over everything above.

Example (thesis, 30-min backups): `HOURLY=24 DAILY=30 WEEKLY=12
MONTHLY=24 YEARLY=all`.

## 2. Fold-merge — the correctness-critical part

A snapshot `B-t` holds the versions **replaced** at run `t`. Deleting a
middle snapshot silently returns wrong versions:

- Runs at 10:00, 10:30, 11:00. `thesis.tex` edited at 10:15 (v0→v1)
  and 10:45 (v1→v2).
- `B-10:30` holds v0, `B-11:00` holds v1, mirror holds v2.
- Keep hourly (10:00, 11:00) → must still be able to get v0 ("state at
  10:00") and v2. Only v1 may be lost.
- Plain-deleting `B-10:30` loses v0 and leaves v1 — the wrong one.

**Rule: when dropping `D`, merge its files into the next newer kept
snapshot `T`, with D's (older) version winning on conflicts.** Then
remove `D`.

Implementation:

1. `rsync -a "D/" "T/"` — source D overwrites T, so older wins.
   (rsync is already a hard dependency; real rsync is enforced.)
2. Verify every path in `D` now exists in `T` (count/compare file
   lists). On mismatch: abort, leave `D` in place, exit 1.
3. `rm -rf D`, `rm -f D.filelist`.
4. Regenerate `T.filelist` with the same `find` used in `backmeup.sh`.

Process dropped snapshots **oldest first**, so a chain D1 < D2 < T
folds D1→D2→… correctly; or merge each directly into its final `T` in
oldest-first order (same result: oldest version wins).

Document the resulting semantics in the manual: after thinning, a kept
snapshot `B-T` holds, for each path, the oldest version replaced
between the previous kept snapshot and `T`.

Out of scope: full point-in-time tree reconstruction (snapshots don't
record the full tree today). Thinning must only guarantee it never
makes version retrieval *wrong*.

## 3. Archived snapshots (v1 scope)

- `B-*.tar.gz` are **never modified or deleted** in v1. They count as
  existing snapshots for bucket selection (they occupy their buckets)
  and are always treated as kept.
- If a dropped dir snapshot's next newer kept snapshot is archived
  (shouldn't happen, since archive goes oldest-first): skip it, keep
  it, warn.
- Docs: set archive age beyond the fine buckets (e.g. archive after
  ~45 days when `DAILY=30`). Repack/thinning of tarballs is a later
  version.

## 4. Script: `bin/backmeup.thin.sh`

```
usage: backmeup.thin.sh [-n|--dry-run] <project>
```

Mirror `archive.sh` conventions (path detection, `backmeup.setup.sh`
sourcing, `basename` of project, error style). Plus:

- **Lock:** take the same per-project lock as `backmeup.sh`
  (`bmuAcquireLock "${BMU_DIRBACKUPS}/<project>/.bmulock"`, `trap`
  release). Thinning must never race a running backup.
- **Safety checks:** same mount check (`*_MOUNT`) and `.bmumeta` check
  as `replicate.sh` (#180) on the BackUp dir.
- **Dry run:** print one line per snapshot — `keep (hourly)`,
  `keep (daily, weekly)`, `merge -> B-…`, `delete (tail)`,
  `keep (archived)`, `keep (KEEP_MIN)` — then a summary. Changes
  nothing.
- **Validation:** each `KEEP_*` is empty, a positive integer, or `all`
  (yearly only); otherwise error, exit 1.
- **Exit:** 0 success / disabled, 1 error.

### Bucket keys

String prefixes of `B-YYYYMMDD-HHMMSS`, no date math:

- hour `YYYYMMDD-HH`, day `YYYYMMDD`, month `YYYYMM`, year `YYYY`

Week needs date math: add `bmuStampToEpoch()` to
`backmeup.shellfunctions.sh` with the same BSD-first / GNU-fallback
pattern as `archive.sh`'s cutoff, parsing the stamp **as UTC** on both
(only relative boundaries matter; avoids DST surprises). Week key =
`(epoch / 86400 + 3) / 7` (Monday-aligned; 1970-01-01 was a Thursday).

## 5. Not in v1

- Not auto-run by `backmeup.sh` or the GUI. Users run it explicitly
  (or in cron after backup). Recommended order:
  `backup → thin → archive → updatedb`.
- No GUI / MCP exposure yet (follow-up PR; MCP tool must be marked
  `destructive_hint=true` + `MUTATING:`).
- No thinning of archived tarballs.

## 6. Tests (shunit2, `tests/test_backmeup.sh`)

Use synthetic `B-<stamp>` dirs with small files; no real backups needed.

1. All `KEEP_*` empty → nothing changes, exit 0.
2. Bucket selection: snapshots across hours/days; `KEEP_HOURLY=2`
   keeps the newest per hour for the last 2 hours; union across rules.
3. **Fold-merge correctness** (the 10:15/10:45 case): after thinning,
   `retrieve` from the kept snapshot returns v0, not v1.
4. Path present only in a dropped snapshot ends up in the target.
5. Chain merge D1 < D2 < T: oldest version wins.
6. Newest snapshot never removed; `KEEP_MIN` respected.
7. Tail snapshots deleted; nothing newer touched.
8. `-n` changes nothing (compare tree before/after).
9. Archived `.tar.gz` untouched and counted in its bucket.
10. Filelists: `T.filelist` regenerated, `D.filelist` removed,
    `locate` finds the merged file under `T`.
11. Refuses when `.bmumeta` missing or lock held.
12. Week bucketing across a year boundary, on both GNU (Linux CI) and
    BSD (macOS CI) `date`.
13. Invalid `KEEP_*` value → exit 1, nothing changed.

## 7. Docs

- `backmeup.setup.sh.template`: the `KEEP_*` variables, commented,
  empty by default.
- `docs/MANUAL.md`: section on thinning, the merge semantics (section
  2), recommended order, thesis example.
- `CLAUDE.md`: update the invariant "archive compresses, never
  deletes" → "archive compresses; thin is the only step that removes
  snapshots, opt-in, via fold-merge".

## 8. Suggested PR split

1. `bmuStampToEpoch` + bucket selection + **dry-run only** (no
   destructive code path yet) + tests 1, 2, 6, 8, 12, 13.
2. Fold-merge + tail delete + lock/safety checks + tests 3–5, 7, 9–11.
3. Template + manual + CLAUDE.md.

## 9. Setup questions (CLI and GUI)

### Shared: presets live in the engine

One source of truth, used by both front ends: a helper
`bmuRetentionPreset <name>` in `backmeup.shellfunctions.sh` that sets
the `BMU_KEEP_*` values. The GUI never hardcodes the numbers; it calls
the engine (`configure.sh --retention=<preset>`) or reads the values
back from `backmeup.setup.sh`.

| Preset | Fits | HOURLY | DAILY | WEEKLY | MONTHLY | YEARLY |
|---|---|---|---|---|---|---|
| `off` (default) | — | | | | | |
| `light` | daily backups | | 14 | 8 | 12 | |
| `standard` | a few backups a day | 24 | 30 | 12 | 24 | 5 |
| `frequent` | thesis / writing, every 10–30 min | 48 | 30 | 12 | 24 | all |
| `custom` | — | user | user | user | user | user |

`BMU_KEEP_MIN=3` for every preset except `off`.

### CLI: `backmeup.configure.sh`

New section right after the replication section, same structure.

**Flags** (non-interactive, scriptable):

```
--retention=off|light|standard|frequent
--keep-hourly=N  --keep-daily=N  --keep-weekly=N
--keep-monthly=N --keep-yearly=N|all  --keep-min=N
```

Individual `--keep-*` flags override the preset's values. Invalid
values → error, exit 1, nothing written.

**Non-interactive without retention flags:** print
`Non-interactive run: thinning left as-is (off by default).` and don't
prompt — same pattern as replication.

**Interactive questions** (default answers keep current behaviour):

```
Thin old snapshots automatically (y/N)?
  Keeps one snapshot per hour/day/week/month; the versions in between
  are merged away. Without this, history grows forever.

Which profile?
  1) light     - daily backups: 14 days, 8 weeks, 12 months
  2) standard  - a few a day: 24 h, 30 days, 12 weeks, 24 months, 5 years
  3) frequent  - every 10-30 min (thesis, writing): 48 h, 30 days,
                 12 weeks, 24 months, then one per year forever
  4) custom
Choice (2):

[custom only]
Hourly snapshots to keep (empty = none): (24)
Daily snapshots to keep (empty = none): (30)
Weekly snapshots to keep (empty = none): (12)
Monthly snapshots to keep (empty = none): (24)
Yearly snapshots to keep (number, 'all', empty = none): (all)
Never keep fewer than: (3)
```

Then print the resulting values and:

```
Preview what would happen before relying on it:
  backmeup.thin.sh -n <project>
```

On re-run, show the current values as defaults and offer `keep as is`
as the default choice.

### GUI

**Where:** a "History retention" step in the setup wizard (after
schedule and replication), and the same panel in the settings page so
it can be changed later.

**Don't ask what can be inferred:** suggest a preset from the
configured schedule (`schedule.rs`): interval under 1 h → `frequent`;
a few per day → `standard`; daily → `light`. Pre-select it, labelled
"Suggested for your schedule". Default remains `off` until the user
picks something.

**Questions shown:**

1. *Keep history forever, or thin it out?* — `Off` / presets / `Custom`
   as cards, each with a one-line plain description, e.g.
   *"Last 48 hours: every snapshot hourly · 30 days: one per day ·
   12 weeks: one per week · 24 months: one per month · then one per
   year."*
2. *Custom* only: number inputs per level, an "all" toggle for yearly,
   and "never keep fewer than".

**Preview before saving (required):** run
`backmeup.thin.sh -n <project>` for each project and show
*"X kept · Y merged into newer snapshots · Z oldest removed"*, with the
per-snapshot list expandable. If there are no snapshots yet: *"Nothing
to thin yet."*

**Confirmation:** when enabling thinning, or lowering any count, show a
confirm dialog with the preview numbers and the line *"Merged versions
can't be recovered."* Raising counts or turning it off needs no
confirm.

**v1 scope:** the GUI saves the setting, shows the preview, and offers
a "Thin now" button that runs `backmeup.thin.sh <project>`
explicitly. Automatic thinning is a follow-up: when added, put it in
`build_housekeeping_wrapper` (`schedule.rs`) in the order
`thin → archive → updatedb → replicate`.

### Tests

- CLI: each preset flag writes the expected `BMU_KEEP_*` values;
  `--keep-*` overrides a preset; invalid value → exit 1, setup
  unchanged; non-interactive run without flags leaves thinning off;
  re-run preserves existing values.
- Engine: `bmuRetentionPreset` values match the table.
- GUI (TS): schedule → suggested preset mapping; custom input
  validation; confirm shown only when enabling or lowering.
- GUI (Rust): dry-run output parsed into kept / merged / removed
  counts.

### PR split addition

4. CLI: `bmuRetentionPreset` + configure flags and questions + tests.
5. GUI: retention step, preview, confirm, "Thin now" + tests.

## Side findings (separate small fixes)

1. `archive.sh` and `unarchive.sh` don't take the per-project lock. An
   archive run concurrent with a backup can tar a snapshot while it's
   being written. Same `bmuAcquireLock` pattern as `backmeup.sh` fixes
   it.
2. **Scheduled replication never runs for the local backend.**
   `build_housekeeping_wrapper` in `gui/src-tauri/src/schedule.rs`
   handles `rclone` and `proton` only; `local` (#144) falls through to
   `_ => {}`, so a USB/local replica is never updated on schedule. Add
   `Some("local") => backmeup.replicate.sh`, plus a test.
