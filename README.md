# bmug2 — BackMeUp generation 2

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
original bmu are fixed and covered by a 20-test regression suite
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
./bin/backmeup.install.sh              # answers a few questions, see the manual
./bin/backmeup.sh --dry-run ~/Documents   # preview
./bin/backmeup.sh ~/Documents             # back it up
./bin/backmeup.locate.sh report.pdf       # find it, current or historical
./bin/backmeup.status.sh                  # see all projects at a glance
```

Full command reference, directory layout, and troubleshooting:
**[docs/MANUAL.md](docs/MANUAL.md)**. Real usage recipes — multiple
projects, excluding files, external drives, cron, upgrading an old bmu
disk: **[docs/EXAMPLES.md](docs/EXAMPLES.md)**. Choosing where SYNC and
HISTORY actually live — local disks, Dropbox/Google Drive, and why S3
needs a different approach: **[docs/DESTINATIONS.md](docs/DESTINATIONS.md)**.

## Design goals

 - A backup readable by "almost any" system: it depends on the
   destination filesystem, not on bmug2 — explore it with `ls` or any
   file manager.
 - Indexed search that still works with nothing but `grep`, even
   without `locate` installed or the backup disk offline.

## MCP server

[`mcp/`](mcp/README.md) exposes bmug2 as tools an LLM assistant can call
— "what's my backup status", "find that file", "preview backing this
up" as natural language. v1 ships read-only tools only (status, search,
and dry-run previews); mutating tools are a deliberate follow-up.

## Future directions

 - A GUI
 - Content indexing (codesearch/zindex) on top of the filename index

## Contributing

Development happens on feature branches merged via pull request; `main`
requires a green CI run (Linux + macOS) before merging. See
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for the exact flow.

## License

See [LICENSE](LICENSE).
