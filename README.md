# bmug2 — BackMeUp generation 2

<!-- unofficially, also a "Beer MUG for 2" -->

[![Tests](https://github.com/mariotti/bmug2/actions/workflows/tests.yml/badge.svg)](https://github.com/mariotti/bmug2/actions/workflows/tests.yml)

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

## Why another backup tool?

Sharing one backup system between a Mac and a Linux box, and wanting
something between a plain backup, a Time Machine, and version control
if you "control" it: `rsync` already does the heavy lifting, and
`updatedb`/`locate` (available on nearly every Unix by default) index
it for searching. No proprietary format: the backup depends only on
the destination filesystem, not on bmug2 itself.

## Requirements

A real rsync (>= 3.x) — `backmeup.sh` detects and refuses to run with
only Apple's openrsync. `updatedb`/`locate` (findutils) for fast
indexing is optional; without it, backups stay searchable via plain
`grep`. See [docs/MANUAL.md](docs/MANUAL.md) for exactly what's
detected and how, and what bmug2's rsync options do and don't preserve
(ACLs, extended attributes, ownership) — worth a read before pointing
this at real data.

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
**[docs/SCHEDULING.md](docs/SCHEDULING.md)**.

## Design goals

 - A backup readable by "almost any" system: it depends on the
   destination filesystem, not on bmug2 — explore it with `ls` or any
   file manager.
 - Indexed search that still works with nothing but `grep`, even
   without `locate` installed or the backup disk offline.
 - Off-site replication as a separate, optional step (`backmeup.replicate.sh`
   via `rclone`) — the local versioned mirror stays fast and local;
   copying it off-site is a deliberate second hop, not the same
   destination. See [docs/DESTINATIONS.md](docs/DESTINATIONS.md).
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
