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
original bmu are fixed and covered by a 63-test regression suite
(`sh tests/test_backmeup.sh`) running in CI on Linux and macOS. It has
not seen long-term use at large scale yet — read
[Requirements](#requirements) before pointing it at real data, and try
[`--dry-run`](docs/MANUAL.md#backmeupsh) first.

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

## MCP server

[`mcp/`](mcp/README.md) exposes bmug2 as tools an LLM assistant can call
— "back this up", "find that file", "what's my backup status" as
natural language. Read-only tools (status, search, dry-run previews)
and mutating ones (backup, archive, unarchive, migrate) are both
implemented; the mutating tools are clearly flagged as such in both
their MCP annotations and their descriptions.

## Desktop GUI

[`gui/`](gui/README.md) is a native Tauri app: install (download the
latest release, or point at an existing install) plus a read-only
dashboard (per-project status, search) — see its README for what's
built so far and what's still CLI-only.

## Future directions

 - Content indexing (codesearch/zindex) on top of the filename index

## Contributing

Development happens on feature branches merged via pull request; `main`
requires a green CI run (Linux + macOS) before merging. See
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for the exact flow.

## License

See [LICENSE](LICENSE).
