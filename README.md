# bmug2 — BackMeUp generation 2

<!-- unofficially, also a "Beer MUG for 2" -->

[![Tests](https://github.com/mariotti/bmug2/actions/workflows/tests.yml/badge.svg)](https://github.com/mariotti/bmug2/actions/workflows/tests.yml)
<!-- Test count is auto-updated by .github/workflows/tests.yml's
     update-test-count-badge job on every push to main - it sums the
     four CI suites' real "N passed" counts (shell + python + rust +
     typescript, all parsed from their actual runner output) and force-
     pushes a single orphan commit to the `badges` branch with a
     shields.io endpoint-badge JSON. The badge below reads that JSON
     directly; a PR branch can't move it (the aggregator only runs on
     push-to-main). -->
![tests](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/mariotti/bmug2/badges/test-count.json)
<!-- Per-component coverage, each its own flag - never a blurred
     repo-wide %. No shell badge: no POSIX-sh coverage tool is packaged
     on Ubuntu 24.04. The bin/*.sh scripts correctly use #!/bin/sh (sh
     is the one shell every Unix guarantees - the right target for a
     portable backup tool), which runs under dash on Ubuntu. bashcov
     and friends hook into bash-specific features (DEBUG trap,
     BASH_XTRACEFD) that don't exist in dash. kcov is the one exception
     - ptrace-based, shell-agnostic - but Ubuntu 24.04 dropped it from
     apt and building from source in CI proved too fragile. The gap is
     in the shell-coverage tooling ecosystem, not the scripts. Deferred.
     Using shields.io's Codecov badge rather than Codecov's own: its
     own badge always prints the generic word "codecov" regardless of
     flag, so all 3 looked visually identical with no way to tell
     which was which at a glance - shields.io bakes the flag name
     itself into the badge as the visible label. -->
[![python coverage](https://img.shields.io/codecov/c/github/mariotti/bmug2?flag=python&label=python)](https://codecov.io/gh/mariotti/bmug2)
[![rust coverage](https://img.shields.io/codecov/c/github/mariotti/bmug2?flag=rust&label=rust)](https://codecov.io/gh/mariotti/bmug2)
[![typescript coverage](https://img.shields.io/codecov/c/github/mariotti/bmug2?flag=typescript&label=typescript)](https://codecov.io/gh/mariotti/bmug2)

A small collection of POSIX shell scripts that turn `rsync` into a
personal backup tool with Time-Machine-style history and locate-style
search — readable with nothing more than `ls`, `find` and `grep`.

This is the continuation of the historical
[bmu](https://github.com/mariotti/bmu) project (preserved unchanged).
bmug2 starts from bmu's last state, fixes its known issues, and adds a
regression test suite and CI. See [Releases](../../releases) for the
version history.

## Status

Personal-use software, actively developed, covered by a real regression
suite (shell + Python for the MCP server, both running in CI on Linux
and macOS — see the badge above). It has not seen long-term use at
large scale yet — read [Requirements](#requirements) below and
[what bmug2's rsync options do and don't preserve](docs/MANUAL.md#backmeupsh)
before pointing it at real data, and try
[`--dry-run`](docs/MANUAL.md#backmeupsh) first.

## Versioning

Semver (`MAJOR.MINOR.PATCH`), with one addition: the MINOR and PATCH
numbers also signal how thoroughly a release was actually exercised
before tagging it, separate from whether CI happened to pass. MAJOR is
unaffected.

- **Odd** MINOR or PATCH = not fully tested yet. Tagged and released
  as `vX.Y.Z-experimental` (a GitHub pre-release) rather than a plain
  `vX.Y.Z`.
- **Even** MINOR or PATCH = tested, against a bar that depends on which
  number moved:
  - **PATCH** odd → even: the automated test suite passing (CI green)
    is enough.
  - **MINOR** odd → even: needs a human to have actually installed and
    run the new code for real - automated tests alone aren't enough.

This isn't sequential: a release can go straight from one odd number
to another odd number (e.g. 2.15.1 → 2.15.3), skipping the even one in
between, when the next build still isn't fully tested either - there's
no requirement to pass through every intermediate value.

This is a provisional policy (as of 2026-10) and may be revisited.

## Why you can trust it with real data

Not marketing — real, verified, defensive behavior, detailed with the
exact bug each one closed in [docs/MANUAL.md](docs/MANUAL.md) and
[docs/SCHEDULING.md](docs/SCHEDULING.md):

 - Refuses to run somewhere it would silently lose data (Apple's
   `openrsync` masquerading as `rsync` on macOS is the real example).
 - Every run takes a per-project lock, so a schedule, a manual `bmu`,
   and the GUI's Run Now can never race into corrupting a snapshot.
 - `backmeup.archive.sh` never deletes before it's verified the tarball
   actually captured everything.
 - Absolute paths baked in at configure time — a scheduled job's
   minimal PATH can't silently swap in the wrong binary.
 - `backmeup.retrieve.sh` can only ever add files to a destination you
   name; it can't touch `SYNC`/`HISTORY` or overwrite anything.

## Disclaimer

bmug2 is personal-use software, provided as-is with no warranty of any
kind — see [LICENSE](LICENSE). Using it as your only safeguard against
data loss is a risk you take entirely on yourself.

**Specific risks worth understanding before you rely on this:**

- **SYNC is a destructive mirror.** `backmeup.sh` runs `rsync
  --delete`, so any file you delete from the source *will be deleted
  from SYNC on the next run*. HISTORY snapshots preserve earlier
  versions, but only up to the last run before the deletion — a backup
  that hasn't run recently won't have them. Run `--dry-run` first on a
  new project and review the output before running for real.
- **Restores are never verified automatically.** The tool writes the
  backup; it does not read it back to confirm the destination is
  intact. Periodically restore a sample of files and check they open
  correctly — do this before you need to.
- **Off-site replication is opt-in and unmonitored.** Configuring
  `backmeup.replicate.sh` (or the GUI's replication panel) does not
  guarantee the off-site copy is current or complete. Check it
  independently.
- **This is not a substitute for a 3-2-1 backup strategy.** bmug2
  covers one copy (local SYNC+HISTORY) plus an optional off-site
  second. A third independent copy on a different medium — one that
  bmug2 itself cannot accidentally overwrite — is your responsibility.
- **Misconfigured paths can cause data loss.** Pointing `backmeup.sh`
  at the wrong source or destination, or running it after a disk
  remounts at a different path, can silently delete files from the
  mirror. Double-check your configured paths after any hardware change.

## Why another backup tool?

Sharing one backup system between a Mac and a Linux box, and wanting
something between a plain backup with versioned history and version control
if you "control" it: `rsync` already does the heavy lifting, and
`updatedb`/`locate` (available on nearly every Unix by default) index
it for searching. No proprietary format: the backup depends only on
the destination filesystem, not on bmug2 itself.

What bmug2 deliberately is and isn't for, who it fits, and a worked
example (backing up a thesis): **[docs/USECASES.md](docs/USECASES.md)**.

## Requirements

**Required:**
- A real `rsync` (>= 3.x) — `backmeup.sh` detects and refuses to run
  with only Apple's `openrsync`. On macOS: `brew install rsync`.

**Optional — install what you need:**
- `updatedb`/`locate` (GNU findutils) for fast indexed search; without
  it, backups stay searchable via plain `grep` but are slower. On
  macOS: `brew install findutils` (installs as `gupdatedb`/`glocate`).
- `rclone` for off-site replication to Google Drive or any other rclone
  remote (`backmeup.replicate.sh --rclone`). On macOS:
  `brew install rclone`.
- `proton-drive` CLI for end-to-end-encrypted off-site replication to
  Proton Drive (`backmeup.replicate.sh --proton`). See
  [docs/DESTINATIONS.md](docs/DESTINATIONS.md) for setup.

See [docs/MANUAL.md](docs/MANUAL.md) for exactly what's detected and
how, and what bmug2's rsync options do and don't preserve (ACLs,
extended attributes, ownership) — worth a read before pointing this at
real data.

## Quick start

```
git clone https://github.com/mariotti/bmug2
cd bmug2
./install.sh                    # a few questions; offers to put `bmu` on your PATH
bmu --dry-run ~/Documents       # preview
bmu ~/Documents                 # back it up
bmu locate report.pdf           # find it, current or historical
bmu status                      # see all projects at a glance
```

Skipped the PATH offer, or calling this from cron/a script? Every `bmu
<subcommand>` above is a shorter name for the matching
`backmeup.<subcommand>.sh`, callable directly by full path from the
install directory instead — see the manual.

One page covering install through ongoing upkeep (reindexing,
archiving, upgrading) without needing the rest of this doc set:
**[docs/QUICK_START_AND_MAINTENANCE.md](docs/QUICK_START_AND_MAINTENANCE.md)**.

Full command reference, directory layout, and troubleshooting:
**[docs/MANUAL.md](docs/MANUAL.md)**. Real usage recipes — multiple
projects, excluding files, external drives, cron, upgrading an old bmu
disk: **[docs/EXAMPLES.md](docs/EXAMPLES.md)**. Choosing where SYNC and
HISTORY actually live — local disks, Dropbox/Google Drive, and why S3
needs a different approach: **[docs/DESTINATIONS.md](docs/DESTINATIONS.md)**.
Running it unattended — cron, `at`, systemd timers, launchd, and the
PATH gotcha that trips up most scheduled jobs:
**[docs/SCHEDULING.md](docs/SCHEDULING.md)**. What bmug2 is (and
deliberately isn't) for, who it fits, and a worked example:
**[docs/USECASES.md](docs/USECASES.md)**.

## Design goals

 - A backup readable by "almost any" system: it depends on the
   destination filesystem, not on bmug2 — explore it with `ls` or any
   file manager.
 - Indexed search that still works with nothing but `grep`, even
   without `locate` installed or the backup disk offline.
 - Off-site replication as a separate, optional step (`backmeup.replicate.sh`
   via `rclone`, or natively to Proton Drive) — the local versioned
   mirror stays fast and local; copying it off-site is a deliberate
   second hop, not the same destination. See
   [docs/DESTINATIONS.md](docs/DESTINATIONS.md).
 - `.gitignore` respected automatically, per project — build artifacts
   and caches never make it into the mirror or history in the first
   place. An opt-in `.bmuignore` adds backup-specific excludes on top.
   See [docs/EXAMPLES.md](docs/EXAMPLES.md#special-setting-respecting-gitignore-and-bmuignore-per-project).

## MCP server

[`mcp/`](mcp/README.md) exposes bmug2 as tools an LLM assistant can call
— "back this up", "find that file", "pull the most important match out
to my Desktop" as natural language instead of shell commands. Every
tool's real risk level (read-only, mutating, or safe-but-not-a-query)
is flagged accurately in its MCP annotations, not just its description.

## Desktop GUI

[`gui/`](gui/README.md) is a native Tauri app: install (download the
latest release, or point at an existing install), a dashboard
(per-project status, search), a tracked list of folders to back up
with an on-demand Run Now, and per-folder scheduling that installs a
real launchd (macOS) or systemd timer (Linux) entry — no plist or unit
file to hand-write. See its README for what's built so far and what's
still CLI-only.

## Future directions

 - Full-text search over archived (compressed) history: a plain-text
   sidecar dump kept next to each `.tar.gz`, the same "keep it
   uncompressed for grep" trick `.filelist` already uses — no new
   index format, no external tool. Live/unarchived snapshots already
   get this for free via `grep -r` on the real files.

## Contributing

Development happens on feature branches merged via pull request; `main`
requires a green CI run (Linux + macOS) before merging. See
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for the exact flow.

## License

See [LICENSE](LICENSE).
