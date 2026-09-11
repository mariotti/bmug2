# bmug2 — BackMeUp generation 2

<!-- unofficially, also a "Beer MUG for 2" -->

A small collection of POSIX shell scripts that turn `rsync` into a
personal backup tool with Time-Machine-style history and locate-style
search — readable with nothing more than `ls`, `find` and `grep`.

This is the continuation of the historical
[bmu](https://github.com/mariotti/bmu) project (preserved unchanged).
bmug2 starts from bmu's last state, fixes its known issues, and adds a
regression test suite and CI. See [Releases](../../releases) for the
version history.

## Status

Personal-use software, actively developed. All issues known from the
original bmu are fixed and covered by a 66-test shell regression suite
(`sh tests/test_backmeup.sh`) plus 48 Python tests for the MCP server,
both running in CI on Linux and macOS. It has not seen long-term use at
large scale yet — read [Requirements](#requirements) and
[What's preserved and what isn't](#whats-preserved-and-what-isnt)
before pointing it at real data, and try
[`--dry-run`](docs/MANUAL.md#backmeupsh) first.

## Why you can trust it with real data

Not marketing — the specific, defensive things the code actually does,
so you can go verify them yourself:

 - **It refuses to run somewhere it would silently lose data.** On
   modern macOS, Apple's `/usr/bin/rsync` is actually **openrsync**,
   which drops `--delete` the moment `--backup` is also active —
   deleted files would just never reach the backup dir, with no error.
   `backmeup.sh` detects this specifically and refuses to run instead
   of backing up "successfully" while quietly not doing what you asked.
 - **Every run takes a lock for its own project**, so a scheduled run,
   a manual `bmu`, and the GUI's Run Now can never race each other into
   corrupting the same snapshot — one of them just cleanly fails
   instead.
 - **`backmeup.archive.sh` never deletes before it's verified.** It
   `tar`s a snapshot to a `.part` file, counts the entries inside that
   archive, and compares that count against the real directory — only
   on a match does it commit the `.tar.gz` and remove the original. Any
   mismatch leaves the snapshot exactly as it was. Most small backup
   scripts delete first and hope; this one only ever removes what it
   just proved it captured.
 - **Absolute paths, baked-in commands, PATH gotchas closed.** A
   scheduled job's minimal PATH can't silently swap in the wrong
   `rsync`/`updatedb`/`rclone` binary — see
   [docs/SCHEDULING.md](docs/SCHEDULING.md) for the real bug this
   closed and how it was found.

## Why another backup tool?

Sharing one backup system between a Mac and a Linux box, and wanting
something between a plain backup, a Time Machine, and version control
if you "control" it: `rsync` already does the heavy lifting, and
`updatedb`/`locate` (available on nearly every Unix by default) index
it for searching. No proprietary format: the backup depends only on
the destination filesystem, not on bmug2 itself.

## Requirements

 - **A real rsync (>= 3.x).** On modern macOS, Apple ships **openrsync**
   as `/usr/bin/rsync`, which silently ignores `--delete` when
   `--backup` is active — deleted files would never reach the backup
   dir. `backmeup.sh` detects this and refuses to run with only
   openrsync available. Fix: `brew install rsync`.
 - **`updatedb`/`locate`** (findutils) for indexing — optional. Without
   it, backups still work and stay searchable via plain `grep` over the
   `.filelist` files; only `gupdatedb`/`glocate` (GNU, via
   `brew install findutils` on macOS), GNU `updatedb`/`locate`, and
   mlocate/plocate are auto-detected.

## What's preserved and what isn't

bmug2's rsync options are `-av --delete --backup` — `-a` (archive mode)
is exactly `-rlptgoD` (verified against this machine's real rsync
3.5.0: recursion, symlinks, permissions, modification times, group,
owner, device files), and rsync's own manual is explicit that `-a`
**does not** include ACLs (`-A`), extended attributes (`-X`), access
times (`-U`), creation times (`-N`), or hardlink detection (`-H`).
Concretely, on macOS: Finder tags, color labels, and quarantine flags
are all stored as extended attributes on APFS, so none of them survive
a backup. File creation ("date added") times don't either — only the
modification time does. Permission bits (`-p`) transfer regardless of
privilege, but **owner (`-o`) only actually transfers when the
receiving rsync runs as root** (verified against this machine's real
rsync manual) — for a typical, non-root personal backup (the normal
way to run bmug2), files in the mirror end up owned by whichever user
ran `backmeup.sh`, not necessarily the source file's original owner.

`--modify-window` (which controls how close two timestamps have to be
to count as "the same") is commented out in the shipped rsync options,
i.e. effectively `0` — exact-second matching. That's fine on a normal
filesystem, but if `BMU_DIRRSYNC` lives on FAT/exFAT, some SMB shares,
or certain cloud-sync mounts (coarser mtime resolution than one
second), every file can look "changed" on every run even when nothing
touched it — spurious re-transfers and needless `--backup` snapshot
churn, not a bug in bmug2 itself. If you hit that, add
`--modify-window=1` (or higher) to `BMU_OPTRSYNC` in your
`backmeup.setup.sh`. See
[docs/DESTINATIONS.md](docs/DESTINATIONS.md) for the fuller picture on
which destination types behave like a normal filesystem and which
don't.

## Storage growth

There's no deduplication. A large file changed repeatedly lands as
that many full copies in `HISTORY`, one per run that changed it — a
video file edited daily for a month is roughly a month's worth of full
copies, not a month of diffs. `backmeup.archive.sh` only compresses
snapshots older than its cutoff (180 days by default), so recent
history grows uncompressed. This was always true, but interval
scheduling (see [docs/SCHEDULING.md](docs/SCHEDULING.md)) makes it
easier to generate many snapshots quickly for a fast-changing project —
know the disk math for what you're backing up, and consider running
`backmeup.archive.sh` with a shorter cutoff for large files that
change often, rather than waiting for the default 180 days.

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

## MCP server

[`mcp/`](mcp/README.md) exposes bmug2 as tools an LLM assistant can call
— "back this up", "find that file", "what's my backup status" as
natural language. Read-only tools (status, search, dry-run previews)
and mutating ones (backup, archive, unarchive, migrate) are both
implemented; the mutating tools are clearly flagged as such in both
their MCP annotations and their descriptions.

## Desktop GUI

[`gui/`](gui/README.md) is a native Tauri app: install (download the
latest release, or point at an existing install), a dashboard
(per-project status, search), a tracked list of folders to back up
with an on-demand Run Now, and per-folder scheduling that installs a
real launchd (macOS) or systemd timer (Linux) entry — no plist or unit
file to hand-write. See its README for what's built so far and what's
still CLI-only.

## Future directions

 - Content indexing (codesearch/zindex) on top of the filename index

## Contributing

Development happens on feature branches merged via pull request; `main`
requires a green CI run (Linux + macOS) before merging. See
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for the exact flow.

## License

See [LICENSE](LICENSE).
