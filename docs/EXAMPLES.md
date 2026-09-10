# bmug2 examples

Real, run-and-verified sessions covering common and not-so-common setups.
For the option-by-option reference, see [MANUAL.md](MANUAL.md); this doc
is about *how* people actually use bmug2 day to day.

Sessions below call the full `backmeup.*.sh` names for clarity about
which command does what. Once bmug2 is on your `PATH` (`install.sh`
offers this), the shorter [`bmu`](MANUAL.md#bmu) dispatcher does the
same thing: `bmu ~/Documents` for `backmeup.sh ~/Documents`, `bmu
status` for `backmeup.status.sh`, `bmu locate` for
`backmeup.locate.sh`, and so on — interchangeable, same output either
way.

## Contents

 - [The basics: one directory, one project](#the-basics-one-directory-one-project)
 - [More than one project](#more-than-one-project)
 - [Special setting: excluding files with rsync options](#special-setting-excluding-files-with-rsync-options)
 - [Special setting: backing up to an external or network drive](#special-setting-backing-up-to-an-external-or-network-drive)
 - [Automating it with cron](#automating-it-with-cron)
 - [Preview before you commit](#preview-before-you-commit)
 - [Finding things again](#finding-things-again)
 - [Housekeeping: status and archiving old snapshots](#housekeeping-status-and-archiving-old-snapshots)
 - [Upgrading a backup disk from the original bmu](#upgrading-a-backup-disk-from-the-original-bmu)

## The basics: one directory, one project

Install once, then back up a directory whenever you like — by hand, or on
a cron job. The project name is just the directory's own name.

```
$ backmeup.sh ~/Documents
sending incremental file list
created directory /Users/alex/Backups/rsyncBackup/Documents
./
scratch.txt
reports/
reports/summary.txt

sent 296 bytes  received 143 bytes  878.00 bytes/sec
total size is 46  speedup is 0.10
```

Edit or delete something and run it again — the old version doesn't
disappear, it moves into history:

```
$ echo 'Q3 revenue: 131,900 (revised)' > ~/Documents/reports/summary.txt
$ rm ~/Documents/scratch.txt
$ backmeup.sh ~/Documents
sending incremental file list
deleting scratch.txt
./
reports/summary.txt

sent 202 bytes  received 61 bytes  526.00 bytes/sec
total size is 30  speedup is 0.11
```

## More than one project

There is no registration step: every directory you point `backmeup.sh`
at becomes its own independent project, named after the directory. Mix
whatever you actually want backed up:

```
$ backmeup.sh ~/Documents
$ backmeup.sh ~/Pictures
sending incremental file list
created directory /Users/alex/Backups/rsyncBackup/Pictures
./
2026-holiday/
2026-holiday/beach.jpg
2026-holiday/sunset.jpg

sent 275 bytes  received 138 bytes  826.00 bytes/sec
total size is 38  speedup is 0.09
$ backmeup.sh ~/code/hobby-site
sending incremental file list
created directory /Users/alex/Backups/rsyncBackup/hobby-site
./
.git/
.git/HEAD
src/
src/app.py

sent 288 bytes  received 144 bytes  864.00 bytes/sec
total size is 36  speedup is 0.08
```

`backmeup.status.sh` shows all of them at a glance, independently:

```
$ backmeup.status.sh
BMU backup status
  SYNC:    /Users/alex/Backups/rsyncBackup
  HISTORY: /Users/alex/Backups/rsyncBackup-BP

PROJECT                  LAST RUN             LAST CHANGE           SNAPSHOTS   MIRROR  HISTORY
Documents                2026-09-07 00:54:57  2026-09-07 00:54:57           1     4.0K      16K
Pictures                 2026-09-07 01:16:13  -                             0     8.0K     4.0K
hobby-site               2026-09-07 01:16:20  -                             0     8.0K     4.0K
```

`Documents` shows a snapshot because it was edited between runs;
`Pictures` and `hobby-site` don't, because nothing has changed in them
yet since their first backup — that's expected, not a problem (see
"if nothing changed, no snapshot is created" in the manual).

Two things worth planning around before you commit to a layout:

 - Two projects with the **same directory name** collide (a project
   `~/code/hobby-site` and `~/other/hobby-site` would both try to use
   the project name `hobby-site`). Nothing stops you from doing this
   today, but the mirror and history for both end up in the same
   `SYNC/hobby-site`. If you have same-named directories, back up their
   *parents* instead, or plan distinct names.
 - There's no config file listing "these are my projects" — if you
   want a fixed set backed up every night, that list lives wherever you
   automate it (see [Automating it with cron](#automating-it-with-cron)).

## Special setting: excluding files with rsync options

The rsync flags bmug2 uses live in `BMU_OPTRSYNC` inside your generated
`backmeup.setup.sh`. It's plain rsync syntax, so anything rsync
supports, you can add — most commonly, excluding build artifacts or
caches you don't want copied into every snapshot:

```
$ grep BMU_OPTRSYNC ~/usr/bmu/bin/backmeup.setup.sh
BMU_OPTRSYNC="-av --delete --backup"
$ sed -i.bak 's/--backup"/--backup --exclude=node_modules --exclude=*.log"/' \
    ~/usr/bmu/bin/backmeup.setup.sh
$ grep BMU_OPTRSYNC ~/usr/bmu/bin/backmeup.setup.sh
BMU_OPTRSYNC="-av --delete --backup --exclude=node_modules --exclude=*.log"
```

With `hobby-site` containing a `node_modules/` directory and an
`app.log` file, the next backup skips both:

```
$ backmeup.sh ~/code/hobby-site
sending incremental file list
./

sent 160 bytes  received 28 bytes  376.00 bytes/sec
total size is 36  speedup is 0.19
$ find ~/Backups/rsyncBackup/hobby-site -type f
/Users/alex/Backups/rsyncBackup/hobby-site/.git/HEAD
/Users/alex/Backups/rsyncBackup/hobby-site/src/app.py
```

Only `.git/HEAD` and `src/app.py` made it in. Don't remove `-av
--delete --backup` from `BMU_OPTRSYNC` — those three flags are load
bearing: `--delete` mirrors deletions, `--backup` is what sends the old
version to history instead of just discarding it, and without `-a`
(archive mode) permissions/times/symlinks stop being preserved.

`--exclude` patterns are evaluated by rsync itself, not bmug2, so the
usual rsync exclude-syntax rules and gotchas apply (leading slash for
project-root-only, trailing slash for directories, etc.) — see `man
rsync`.

## Special setting: backing up to an external or network drive

`backmeup.configure.sh` just asks for a directory; it can be anywhere
your system can write to, including a mounted external disk or a
network share. For the fuller picture — cloud-sync folders like
Dropbox/Google Drive, and why S3 needs a different approach entirely —
see [DESTINATIONS.md](DESTINATIONS.md).

```
Please type the SYNC directory: (/Users/alex/Backups/rsyncBackup)
/Volumes/BackupDrive/rsyncBackup
Please type the BackUp directory: (/Volumes/BackupDrive/rsyncBackup-BP)

Please type the IndexDB directory: (/Volumes/BackupDrive/rsyncBackup/.locate.dir)
```

Things worth knowing before you do this:

 - If the drive is **unmounted or disconnected**, `backmeup.sh` will
   simply fail to find the directory and error out — it won't silently
   back up to the wrong place. Safe, but check your cron job's output
   occasionally rather than assuming silence means success.
 - **Avoid a space in the mount path** if you rely on indexed search
   (`backmeup.updatedb.sh`/`backmeup.locate.sh`): GNU findutils'
   `updatedb --localpaths` can't index a root containing a literal
   space (see the manual's troubleshooting section). Backup, migrate
   and archive are unaffected either way.
 - A slow network share makes the very first backup of a large
   directory slow (it's a full copy); subsequent runs are only as slow
   as what actually changed, same as any rsync-based tool.

## Automating it with cron

bmug2 has no daemon or scheduler of its own — cron (or launchd, or
systemd timers) is the intended way to run it unattended. A simple
crontab backing up three projects nightly and reindexing once
afterward:

```
# m h  dom mon dow   command
0  2   *   *   *     /Users/alex/usr/bmu/bin/backmeup.sh /Users/alex/Documents
5  2   *   *   *     /Users/alex/usr/bmu/bin/backmeup.sh /Users/alex/Pictures
10 2   *   *   *     /Users/alex/usr/bmu/bin/backmeup.sh /Users/alex/code/hobby-site
30 2   *   *   *     /Users/alex/usr/bmu/bin/backmeup.updatedb.sh
0  3   1   *   *     /Users/alex/usr/bmu/bin/backmeup.archive.sh Documents
```

Notes:

 - Full paths everywhere — cron doesn't source your shell rc file, so
   even if you accepted `install.sh`'s offer to put `bmu`/`backmeup.*.sh`
   on `PATH` for interactive shells, cron jobs still need the full path.
 - Stagger the backup jobs a few minutes apart if they share a slow
   disk; running `updatedb.sh` only after they've all finished avoids
   indexing a half-written backup.
 - The monthly `archive.sh` line uses the default 180-day cutoff (no
   number after the project name) — see
   [Housekeeping](#housekeeping-status-and-archiving-old-snapshots).
 - Redirect cron's own mail (`MAILTO=`) or check `backmeup.status.sh`
   periodically — a backup that silently stops running is worse than
   one that never ran, because it looks fine from a distance.

## Preview before you commit

`--dry-run` (or `-n`) runs the real safety checks and shows exactly
what rsync would copy, delete, and archive — without touching
anything. Worth making a habit of before pointing bmug2 at something
new, or after editing `BMU_OPTRSYNC`:

```
$ backmeup.sh --dry-run ~/Documents
sending incremental file list
created directory /Users/alex/Backups/rsyncBackup/Documents
./
scratch.txt
reports/
reports/summary.txt

sent 162 bytes  received 103 bytes  530.00 bytes/sec
total size is 46  speedup is 0.17 (DRY RUN)

DRY RUN: no files were copied, deleted, archived or indexed.
```

## Finding things again

`backmeup.locate.sh` searches the current mirror and full history
together, plus any archived (compressed) snapshots via a plain-text
fallback — one command, no need to remember which snapshot something
was in:

```
$ backmeup.updatedb.sh
$ backmeup.locate.sh scratch.txt
/Users/alex/Backups/rsyncBackup-BP/Documents/B-20260907-005457/scratch.txt
```

That's the deleted `scratch.txt` from the "edit and delete" example
above — gone from the live mirror, found instantly in its snapshot.

## Housekeeping: status and archiving old snapshots

`backmeup.status.sh` is the "is everything actually working" check —
run it after setting up cron, or any time you're unsure:

```
$ backmeup.status.sh
BMU backup status
  SYNC:    /Users/alex/Backups/rsyncBackup
  HISTORY: /Users/alex/Backups/rsyncBackup-BP

PROJECT                  LAST RUN             LAST CHANGE           SNAPSHOTS   MIRROR  HISTORY
Documents                2026-09-07 00:54:57  2026-09-07 00:54:57           1     4.0K      16K
```

Old snapshots accumulate over time; `backmeup.archive.sh` compresses
the ones past a given age (180 days by default) and keeps them
searchable:

```
$ backmeup.archive.sh Documents 0
Archiving Documents snapshots older than 0 days (before 20260907-005516)
archived B-20260907-005457 -> B-20260907-005457.tar.gz (4 entries verified)
1 snapshot(s) archived.
$ backmeup.locate.sh scratch.txt
/Users/alex/Backups/rsyncBackup-BP/Documents/B-20260907-005457/scratch.txt (archived)
```

(`0` days is used here only to make an example snapshot archivable
immediately — in real use, pass nothing for the 180-day default, or
whatever cutoff fits how much history you actually want to keep before
trading instant access for disk space.)

Changed your mind about one? `backmeup.unarchive.sh <project>
<snapshot>` puts it back exactly as it was:

```
$ backmeup.unarchive.sh Documents B-20260907-005457
restored B-20260907-005457 (archive removed)
```

## Upgrading a backup disk from the original bmu

If you're pointing bmug2 at a disk that was backed up with the
original bmu, the mirror is nested one level deeper than bmug2 expects
(`SYNC/<project>/<project>/` instead of `SYNC/<project>/`). bmug2
notices and refuses rather than risk re-archiving your entire old
backup:

```
$ backmeup.sh ~/OldStuff
ERROR: old bmu layout detected: /Users/alex/Backups/rsyncBackup/OldStuff/OldStuff
bmug2 mirrors the project directly in /Users/alex/Backups/rsyncBackup/OldStuff.
Migrate once (instant rename, no re-transfer):
  /Users/alex/usr/bmu/bin/backmeup.migrate.sh OldStuff
```

Run the suggested command once per project — it's a same-filesystem
rename, effectively instant regardless of how large the project is:

```
$ backmeup.migrate.sh OldStuff
Migrated: /Users/alex/Backups/rsyncBackup/OldStuff now mirrors the project directly.
The next backmeup.sh run should transfer (almost) nothing.
$ backmeup.sh ~/OldStuff
sending incremental file list

sent 82 bytes  received 19 bytes  202.00 bytes/sec
total size is 22  speedup is 0.22
```

`sent 82 bytes` for the whole project confirms it: rsync found nothing
worth re-sending, exactly as promised. Historical `B-<date>` snapshots
from before the migration keep their old nesting and remain fully
searchable — only the live mirror needed fixing.
