# WARNING this code is at GAMMA stage

Wrong settings can ovewrite your data.

# bmug2

BackMeUp generation 2 - A tool to make backups for personal use. Also system wide and embedded devices.

This is the continuation of the historical [bmu](https://github.com/mariotti/bmu) project,
which is preserved unchanged. bmug2 starts from the last bmu state and fixes the basic issues.

## Requirements

 - A **real rsync** (>= 3.x). On modern macOS Apple ships **openrsync** as
   `/usr/bin/rsync`, which **silently ignores `--delete` when `--backup` is
   active** — deleted files would never reach the backup dir. The setup now
   auto-detects a usable rsync (`BMU_CMDRSYNC`) and `backmeup.sh` refuses to
   run if only openrsync is found. Fix: `brew install rsync`.
 - `updatedb`/`locate` (findutils) for indexing. On macOS: `brew install findutils`
   (provides `gupdatedb`/`glocate`).

## Tests

    sh tests/test_backmeup.sh

Runs the regression suite (bundled shunit2): two real backup runs in a
temporary sandbox, then asserts on the mirror, the archived old/deleted
versions, the filelists, indexing and search. Index/search tests are
skipped on machines without findutils.

## How it currently works: we want to improve this

 - install: run backmeup.install.sh
 - backup: run backmeup.sh as many times as you need or set it on a cron job
 - index: run backmeup.updatedb.sh any now and then or setup a nightly cron job
 - search: run backmeup.locate.sh

## Target Requirements

  - A backup which is readable by "almost any" system. As a matter of facts the current backup system depends
    only on the backup device and not on the backup software. The basic software currently is "updatedb" and
    "locate" from the findutils package, which are widely available as default system software.
    There are plans to introduce additional (read to add on top of the current system) indexing software
    to improve the search.
    
  - A backup which I explore by simply listing files with "ls" or with any modern file manager.

## Why another backup tool?

I was, and I am still, not happy with all the tools around. Also lately I started to use a light mac machine
for quick everyday work. My current linux box is even lighter, and I use it for high load programming.
This made things even worst: sharing a personal backup system within OSs.

The Mac OS Time Machine was a nice discovery and finding that I can do the same with the
Unix command "rsync" was even better.

What I propose is something between a backup, a time machine and close to version control if you "control" it.

## Future directions

 - The first is indeed to make it stable and generally usable.
 - A GUI
 - An archive facility to compress very old data which will still include an indexing/search facility

# News

## Fixed: double-nested mirror layout (migration required for old backups)

The mirror now lives directly in `SYNC/<project>/` instead of the accidental
`SYNC/<project>/<project>/` of the original bmu. New `B-<date>` snapshots are
flatter too (`B-<date>/file` instead of `B-<date>/<project>/file`).

**Compatibility:** running against an old-layout mirror would archive the
whole old tree and re-transfer everything, so `backmeup.sh` detects the old
layout and refuses. Migrate once per project with:

    backmeup.migrate.sh <project>

It is an instant same-filesystem rename that preserves mtimes: the next
backup transfers nothing. Historical `B-<date>` snapshots are left untouched
(they keep the extra level; search still finds everything in them). The
migration script refuses ambiguous cases (a project legitimately containing
a same-named subdirectory) instead of guessing.

## Fixed: indexing works again, "gnu or m?" resolved

The old open question — GNU findutils vs mlocate — is now handled by capability
detection instead of `uname` (which also had a `$UNAME`/`$BMU_UNAME` typo that
disabled the macOS branch entirely). The setup probes for `gupdatedb` (Homebrew
findutils on macOS), then `updatedb`, and picks the right dialect:
GNU (`--localpaths=`) or mlocate/plocate (`-U`). Searching (`locate -i -d`) is
identical across all of them. If no updatedb exists, `backmeup.sh` warns and
skips indexing (the `.filelist` files still provide a zero-dependency search)
while `backmeup.updatedb.sh` fails with instructions. The unused `bbe`
dependency is gone.

Verified end to end on macOS: backup, per-run index, full reindex, and
`backmeup.locate.sh` finding both current and historical file versions.

## Fixed: deleted files were not archived (macOS/openrsync + rsync 3.4+ bug)

Two stacked issues around the core "deleted files go to the backup dir" promise:

 - Apple's openrsync drops `--delete` when `--backup` is active. bmug2 now
   detects it and requires a real rsync (see Requirements).
 - Real rsync >= 3.4 fails delete-phase backups with `make_backup(...): File
   exists` when the `--backup-dir` path has 2+ missing leading components —
   exactly our `sync-BP/<project>/B-<timestamp>` layout. `backmeup.sh` now
   pre-creates the project level so only the timestamped dir is left to rsync.

Verified end to end in a sandbox: changed files and deleted files both land in
`B-<timestamp>/`, and the mirror is a true mirror again.

## Tested on linux

Finally I got back to my linux box and tested it!

I realised the problem is not linux or mac but more gnu version or mlocate.

This will need to create an other issue. gnu or m?
