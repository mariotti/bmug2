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

Current scratch location: `~/.cache/bmug2-sim-wip/`

- `run-baseline.sh` — host orchestrator. Starts Lima VM, runs the sim
  inside, tears down. Trap: delete VM on exit regardless of outcome.
- `sim-inside-vm.sh` — the sim itself. Installs bmug2, generates the
  tree, runs the calibration SYNC + sim loop + verification.
- `README.md` — this file.

Once Phase 2 is also working, these transplant to `tools/sim/` in
the repo + a Makefile target (`make test-sim-baseline`).

## Phased plan

- **Phase 1 — baseline (done, this doc).** No disruption; confirm the
  deterministic claim + measure baseline performance.
- **Phase 2 — deletion.** User deletes a file at random time; verify
  recovery via `backmeup.retrieve.sh` works. Starts needing
  Monte-Carlo infra (N trials, seeded).
- **Phase 3 — crash.** SIGKILL a running backup; verify the lock
  recovers cleanly on the next run.
- **Phase 4 — tree-shape sweep.** Run baseline across `flat-few` (10
  big files), `flat-many` (100 small, current default), `deep` (100
  files, depth 5, fanout 3). Produce a timing table.
