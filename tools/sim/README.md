# bmug2 end-to-end backup sim

Runs bmug2 against a controlled, machine-generated data tree inside a
Fedora Lima VM, with time-compressed emulation of user edits + SYNC +
HISTORY cycles. Measures what the backup system actually does under
realistic timing, not what unit tests say it should do.

## Design decisions

- **Time compression: 1 real day = 60 simulated seconds** (1440×).
  Picked for a self-consistent mapping across all intervals:
    - User edit every ~1 real hour → ~2.5s sim
    - SYNC every ~2 real hours → ~5s sim
    - HISTORY snapshot daily → ~60s sim
    - 1 real week elapsed → ~7 sim minutes
  This stays coherent as long as a single SYNC completes well under the
  2.5s edit interval; Phase 1 confirms it does at the baseline tree
  size (~1 MB, 100 files).

- **One distro: Fedora** via Lima's `template://fedora`. Scope-limiting
  decision — expanding to Rocky/Alma later is a one-line matrix add if
  needed, but one distro is enough to verify the backup logic itself.

- **No core code changes**. The sim lives entirely outside `bin/`,
  `gui/`, `mcp/`, and `tests/`. It drives the installed bmug2 CLI from
  outside via a non-interactive `install.sh` + repeated `backmeup.sh`
  calls. Keeps the sim orthogonal to the thing it's testing.

- **Lima VM: 2 CPU / 2 GiB / 20 GiB.** Matches the host-friendly
  nice-spot from PR #167. Per-run VM name uses a PID suffix
  (`bmug2-sim-fedora-$$`) and gets deleted on exit.

## Phase 1 — baseline (no disruptions)

Goal: confirm the deterministic claim holds on real runs — "SYNC at
time T captures the state at T; the newest HISTORY snapshot captures
the state replaced by that SYNC."

### Setup

- `flat-many` tree preset: 100 files × 10 KB each, flat (one dir)
- 2 tracked files (`f001.txt`, `f002.txt`) edited across cycles; the
  other 98 are unchanged ballast to make rsync's work realistic
- 10 cycles × (2 edits + 1 SYNC) per cycle = 20 edits, 10 SYNCs

### Results from the first clean run

```
Checks:   40 passed / 0 failed
SYNC avg: 0.067s  min: 0.053s  max: 0.077s  (cal: 0.055s)
After 10 cycles: SYNC=1.2M, HISTORY=288K, snapshots=10
```

- **Deterministic claim: confirmed.** Every cycle's SYNC content
  matched the version just written; every cycle's HISTORY snapshot
  contained the prior version.
- **SYNC time:** 55-77 ms, well under the 2.5s edit interval — the
  1440× compression ratio holds comfortably at this tree size.
- **HISTORY growth:** 288 KB for 10 snapshots × 2 modified files ×
  10 KB each ≈ 24 KB/snapshot overhead (filelist + dir metadata),
  consistent with bmug2's documented behavior.

### Observations worth remembering

1. **rsync's mtime window matters more than you'd think.** The first
   iteration failed on cycle 1's first edit — a file modified
   milliseconds after the previous SYNC's write of the same file can
   be skipped by rsync as "unchanged" (same size, mtime indistinguishable
   at the comparison precision). A human won't hit this because humans
   don't type faster than rsync; the sim does because of the time
   compression. Fix: a 1s "safety sleep" after calibration before the
   main loop starts.

   **Heuristic worth testing later:** at what edit interval does this
   start biting under realistic user cadence? If the answer is
   "sub-second," real users are safe. If it's "a few seconds," users
   with aggressive save-on-every-keystroke editors could lose
   intra-second edits.

2. **`/tmp` on Fedora is tmpfs**, ~1 GiB cap on a 2 GiB VM — too small
   for even a bare bmug2 source copy (with `.git`). Use the guest's
   `$HOME` (`/home/mariotti.guest/`, disk-backed) as the sim's working
   root instead.

3. **Lima mounts the host `$HOME` read-only.** `backmeup.configure.sh`
   writes `backmeup.setup.sh.new` into the source `bin/` directory
   before `install.sh` relocates it, which fails against a read-only
   mount. Fix: copy the source to a writable VM-local path first via
   `rsync -a --exclude='.git/'`.

4. **Lima's guest `$HOME` differs from the host mount path.** Host's
   `/Users/mariotti` is mounted at `/Users/mariotti` inside the VM
   (not `/home/mariotti.guest`). The sim-inside-vm script can't use
   `$HOME` to find the host repo — it uses `BMUG2_SOURCE` passed as
   env from the host orchestrator.

### Future heuristic tests implied

Future sim phases could derive and verify rules like:

- **"Compression ratio N× is safe iff single SYNC completes in less
  than (edit interval / safety factor) seconds."** Phase 1 confirms
  the ratio holds at 1440×/0.067s SYNC. Should hold through at least
  10× that SYNC time; past that, the sim can't keep up and the
  measured intervals stretch.

- **"Safe edit-to-SYNC gap under rsync's mtime window is Xms."**
  Testable by varying the edit→SYNC delay and seeing when rsync
  starts skipping.

- **"HISTORY overhead per snapshot grows O(1) with file count,
  O(changes) with modified-file count."** Testable with the other
  tree presets (`flat-few`, `deep`) and comparing per-snapshot sizes.

## Scripts

- `run-baseline.sh` — host orchestrator. Starts Lima VM, runs the sim
  inside, tears down. Trap: delete VM on exit regardless of outcome.
  Reads `BMUG2_SOURCE` (defaults to repo root) and `PRESET` env.
- `sim-inside-vm.sh` — the sim itself. Installs bmug2, generates the
  tree, runs the calibration SYNC + sim loop + verification.
- `README.md` — this file.

Entry points via the top-level `Makefile`:

- `make test-sim-baseline` — default preset `flat-many`
- `make test-sim-baseline PRESET=deep` — explicit preset
- `make test-sim-sweep` — all three presets back-to-back
- `make test-sim-clean` — tear down any leftover VMs

## Tree-shape sweep (Phase 1 extended)

Three presets, same 10-cycle sim loop, same compression ratio, run
back-to-back via `make test-sim-sweep`. Each preset uses a fresh VM;
run on this host (M-series Mac):

| Preset | Files | Size each | Dirs | Tree | SYNC avg | SYNC max | HISTORY/10 | SYNC size |
|---|---|---|---|---|---|---|---|---|
| `flat-few` | 10 | 1 MB | 1 | ~10 MB | 77 ms | 95 ms | 21 MB | 11 MB |
| `flat-many` | 100 | 10 KB | 1 | ~1 MB | 62 ms | 86 ms | 288 KB | 1.2 MB |
| `deep` | 100 | 100 KB | 153 | ~10 MB | 76 ms | 102 ms | 2.1 MB | 11 MB |

Pattern-level observations:

- **SYNC time is remarkably flat across tree shapes** (62-77 ms avg).
  The 100× difference in file count (`flat-few` vs `flat-many`) is
  barely visible, and the 153× difference in dir count (`flat-many`
  vs `deep`) adds only ~15 ms. rsync's walk is dominated by stat()
  cost per file; 100-10000 files is still cheap on an aarch64 VZ VM.
- **HISTORY grows linearly with modified-file size, not tree size.**
  `flat-few`'s 2 × 1 MB per snapshot = 20 MB over 10 cycles;
  `flat-many`'s 2 × 10 KB = 200 KB + overhead; `deep`'s 2 × 100 KB =
  2 MB. The claim "HISTORY scales with CHANGES, not with tree size"
  is empirically confirmed.
- **Compression ratio holds at every tree size tested.** Worst SYNC
  was `deep`'s 102 ms — still ~24× under the 2.5s edit-interval
  budget. The 1 day = 60s mapping has significant headroom; a
  working-tree ~10× bigger than any tested here would still fit.

## Phase 2 — deletion scenario

Simulates the "user accidentally deleted a file" story end-to-end:

- The sim runs its normal baseline cycles, but at a chosen cycle K it
  **deletes** the second tracked file (`f002.txt`) instead of editing it.
- After the SYNC that follows the deletion, the sim verifies three
  deterministic claims:
  - (a) the file is gone from SYNC;
  - (b) the latest HISTORY snapshot contains the file with its
    pre-deletion content (`file-f002-vK-1`);
  - (c) **`backmeup.retrieve.sh` pulls it back into a scratch dir and
    the content matches** — end-to-end confirmation that recovery
    actually works, not just that the file exists in HISTORY.
- For the remaining cycles (K+1 … 10), the file stays absent from
  SYNC; the sim keeps running against the other tracked file to
  prove the backup system doesn't get confused by the deletion.

### Picking the deletion cycle

Two modes:

```sh
# Predictable: fixed cycle, same every run
make test-sim-deletion DELETE_AT_CYCLE=5

# Seeded random: $SEED → cycle in [3, 8]. Default SEED=42.
make test-sim-deletion
make test-sim-deletion SEED=17
```

The seeded picker uses bash's own `$RANDOM`, re-seeded from `SEED`. Range
[3, 8] is chosen so there's always prior HISTORY to recover from AND
post-deletion cycles to prove the sim keeps running cleanly.

### Observed on this host

| Mode | Cycle | Recovery time | Snapshot |
|---|---|---|---|
| `DELETE_AT_CYCLE=5` | 5 | 5 ms | `B-<time>` |
| `SEED=42` (default) | 3 | 6 ms | `B-<time>` |

Recovery is near-instantaneous because `backmeup.retrieve.sh` just
copies a single file from HISTORY — no decompression, no rsync, no
scanning. The real risk this verifies is the **existence** path (that
HISTORY actually contains the pre-delete version with the right
content), not the speed path.

## Phase 2.5 — N trials (Monte-Carlo over seeds)

Same deletion scenario, N trials back-to-back. Each trial:

- Gets its own derived seed (`SEED + trial - 1`) → different
  `delete_at_cycle` per trial if DELETE_AT_CYCLE is unset
- Starts from a fresh tree + fresh SYNC/HISTORY (no cross-trial
  contamination) but reuses the same bmug2 install
- Runs the full 10-cycle sim + the 3 deletion checks

The outer loop aggregates per-trial pass/fail + records
delete_at_cycle, SYNC avg, and recovery time per trial. Final report
shows totals + ranges.

```sh
make test-sim-deletion TRIALS=3              # 3 trials, seeds 42/43/44
make test-sim-deletion TRIALS=10 SEED=100    # 10 trials, seeds 100..109
make test-sim-deletion TRIALS=5 DELETE_AT_CYCLE=5  # 5 trials, fixed cycle 5
```

Observed with `TRIALS=3`:

| Trial | Seed | Delete cycle | Recovery |
|---|---|---|---|
| 1 | 42 | 3 | 9 ms |
| 2 | 43 | 7 | 6 ms |
| 3 | 44 | 8 | 6 ms |

Aggregate: 3/3 trials passed, SYNC avg 0.074s across trials
(per-trial range 0.071s..0.076s), recovery 6-9 ms. Each trial got a
clean slate — the `reset_data_dirs` + `generate_tree` call at the
top of each trial erases any SYNC/HISTORY state from the previous
one, so trial N's results are independent of trial N-1's.

## Phased plan

- **Phase 1 — baseline (done).** No disruption; confirm the
  deterministic claim + measure baseline performance across three
  tree-shape presets. Sweep table above.
- **Phase 2 — deletion (done).** User deletes a file at a chosen
  cycle; verify recovery via `backmeup.retrieve.sh` end-to-end.
  Predictable (fixed cycle) and seeded (random in [3,8]) modes.
- **Phase 2.5 — N trials (done).** Loop Phase 2 with derived seeds;
  aggregate pass/fail + stats across trials. Table above.
- **Phase 3 — crash.** `SIGKILL` a running backup; verify the lock
  recovers cleanly on the next run.
