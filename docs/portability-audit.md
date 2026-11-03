# bmug2 shell portability audit — 2026-11-02

Reference document, not a spec. Snapshot of every external command
used in `bin/*.sh` as of main `a4f4f00`, ranked by long-term
portability risk. Four tiers from "survives forever" to "will
probably rot in a release or two". Refresh periodically, and
whenever a new external dep is added (particularly anything
macOS-internal or vendor-specific).

## Tier 1 — POSIX core, bulletproof

Standardized by IEEE 1003.1 and in Unix for 35+ years. Flags
listed are the ones bmug2 actually uses.

| Command | Flags used | 5y | 10y |
|---|---|---|---|
| `echo`, `printf`, `cat` | — | 100% | 100% |
| `cp` | `-R -p` | 100% | 100% |
| `mv`, `rm -rf`, `mkdir -p`, `rmdir`, `chmod`, `chown` | — | 100% | 100% |
| `ls -A -1`, `basename`, `dirname`, `pwd`, `cd` | — | 100% | 100% |
| `touch`, `kill`, `sleep`, `test / [ ]`, `read` (builtin), `command` (builtin) | — | 100% | 100% |
| `grep -q -E -c -v -l -n` | — | 100% | 100% |
| `head -n`, `tail -n`, `sort`, `wc -l`, `tr`, `cut -c`, `expr` | — | 100% | 100% |
| `tar -c -x -z -t -f` | gzip-via-tar | 100% | 100% |
| `find -type -name` | no `-maxdepth` | 100% | 100% |
| `tee -a`, `mkfifo`, `mktemp` | — | 100% | 95% |
| `od`, `hostname` | — | 100% | 100% |

**All of the above you can trust forever.** The project uses them
cleanly.

## Tier 2 — GNU/BSD divergent, project already handles

These are POSIX commands whose *flags* or *output format* differ
between the two main lineages. bmug2 has active workarounds for
each:

| Command | Divergence | Project's workaround | 5y | 10y |
|---|---|---|---|---|
| `date` | GNU `-d "spec"` vs BSD `-j -f fmt input` | Try BSD first, fall back to GNU — see `archive.sh:60-67` and `bmuStampToEpoch` | 95% | 90% |
| `df -P` | `-P` locks POSIX column layout (both honor it) | `bmuMountPoint` uses `df -P` + awk `$NF`, deliberately avoids `stat` whose GNU/BSD split is worse | 95% | 95% |
| `tail -r` vs `tac` | BSD-only vs GNU-only, same operation | `tail -r 2>/dev/null \|\| tac` fallback | 95% | 90% |
| `du -sh` | `-h` was non-POSIX for years, standardized ~2004 | Used everywhere; safe now | 100% | 100% |
| `stat` | `-c` (GNU) vs `-f` (BSD) format strings — fully incompatible | **Avoided entirely** — explicit comment in `bmuMountPoint` saying so | n/a | n/a |
| `sed -i` | `-i ''` (BSD) vs `-i` (GNU) — syntactic hell | **Not used in `bin/`** at all; sed only in filter mode. Smart. | n/a | n/a |

The project did its homework on this tier. Risk ≈ 0 as long as
`date` or similar doesn't drop a syntax, which they don't.

## Tier 3 — External tools we hard-depend on

These are the real portability risk. Each is a separate project
with its own release cadence, maintainer, and bus factor.

| Tool | Role | Alternatives | 5y | 10y | Comment |
|---|---|---|---|---|---|
| **rsync** | all file transfers, backup core | openrsync (incomplete), xrsync (abandoned), bsync (abandoned) | 99% | 95% | Multiple active forks, 30 years of history, won't die. BUT: Apple shipped **openrsync** as `/usr/bin/rsync` on macOS ≥15 and it silently drops `--delete` under `--backup`. Project refuses it in `bmuDetectRsync`. The underlying risk now: as Apple's openrsync matures, it might become "the rsync" and real rsync becomes legacy. Not likely in 5y, possible in 10y. |
| **rclone** | off-site replication to any cloud remote | restic (different model), b2cli (B2-only), awscli (AWS-only) | 95% | 85% | Single project, single maintainer (Nick Craig-Wood) with ~20 regular contributors. 10M+ GitHub downloads/year. Healthy but single-source. If that stops, no drop-in. |
| **proton-drive CLI** | native Proton Drive upload | rclone's protondrive backend, Proton's web/desktop clients | 70% | 40% | Proton's own tool; fate tied to Proton's business + their priorities on CLI vs app. **Highest-risk** external dep. Already a backend you can skip. |
| **updatedb/locate** | search index | mlocate, plocate, GNU findutils | 95% | 90% | Multiple active forks (mlocate deprecated → plocate ascendant). Project uses capability detection, not uname. |
| **gupdatedb/glocate** (Homebrew GNU findutils) | macOS-side GNU dialect | — | 90% | 85% | Depends on Homebrew's `findutils` formula. Could get renamed; the detection loop would need updating. |
| **gzip** (via `tar -z`) | archive compression | zstd, xz | 100% | 100% | Universal, in POSIX indirectly via tar+pipe. |

## Tier 4 — macOS-specific, my own addition is in this tier

| Tool | Where | 5y | 10y | Honest take |
|---|---|---|---|---|
| **`fileproviderctl`** | `backmeup.replicate.status.sh` (new in #194) | 50% | 20% | ⚠️ **The one I added.** `/usr/bin/fileproviderctl` is Apple's **internal** tool, no man page, no documented contract. I parse `nev:N ev:N` from its `dump` subcommand's output — which could change in any macOS point release. The guard IS capability-gated (`command -v fileproviderctl` + provider match), so if it breaks the whole upload-queue field just goes empty — the rest of status.sh still works. Still, this is the one thing built on top of unstable ground. |
| **`brctl`** | not currently used | — | — | iCloud-specific equivalent. We don't touch it. |
| **`launchctl`** / **launchd plists** | GUI's schedule installer (`gui/src-tauri/src/schedule.rs`) | 95% | 90% | Apple-provided, stable public API, Apple's own `launchd` has been the system init since 2005. |
| **`systemctl`** / systemd units | GUI's schedule installer (Linux side) | 95% | 95% | De facto standard on all mainstream distros. |

## Overall assessment

- **The shell suite in `bin/*.sh` is genuinely portable.** The
  authors avoided `sed -i`, avoided `stat`, used `df -P` not
  `df -h`, capability-detected everything. Really careful work.
- **The one shaky new piece is `fileproviderctl` in `status.sh`.**
  It's optional and gracefully fails, but worth being explicit
  about: Apple could break the parse in macOS 27 and we'd lose
  the queue field. Not a blocker; worth documenting in the code
  comment.
- **Proton Drive CLI** is the highest-risk external dependency.
  Already optional + replaceable by the `local` backend route or
  rclone's `protondrive` remote.
- **rclone's single-source** nature is the longer-term question.
  5y safe, 10y maybe-not. If rclone ever stalls, the migration
  path would be adding more backends (restic, borg, native
  backend-specific tools).

## Actions worth considering

Nothing in the audit flags a change you need to make now, but two
items worth noting:

1. **Add a code comment to `backmeup.replicate.status.sh`** on the
   `fileproviderctl` fragility — currently flagged in commit
   message, should also be in the code so a future reader sees it
   immediately.
2. **Follow-up (defer)**: evaluate rclone's `protondrive` remote
   as a replacement for the dedicated `proton-drive` CLI backend —
   simplifies the project to two backends (rclone + local) at the
   cost of pulling Proton's E2E into rclone's slightly more
   complex config.
