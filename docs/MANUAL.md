# bmug2 manual

Full command reference for bmug2. For what the project is and why, see
the [README](../README.md).

## Contents

 - [Directory layout](#directory-layout)
 - [Install and configure](#install-and-configure)
 - [Commands](#commands)
   - [backmeup.sh](#backmeupsh)
   - [backmeup.status.sh](#backmeupstatussh)
   - [backmeup.locate.sh](#backmeuplocatesh)
   - [backmeup.updatedb.sh](#backmeupupdatedbsh)
   - [backmeup.archive.sh](#backmeuparchivesh)
   - [backmeup.unarchive.sh](#backmeupunarchivesh)
   - [backmeup.migrate.sh](#backmeupmigratesh)
 - [Troubleshooting](#troubleshooting)

## Directory layout

Three directories, set during configuration (defaults shown):

```
~/tmp/rsyncBackup            SYNC: the current mirror, one subdir per project
~/tmp/rsyncBackup-BP         HISTORY: old and deleted versions, per project
~/tmp/rsyncBackup/.locate.dir   the search index
```

Inside SYNC, a project is a plain mirror of its source directory:

```
SYNC/<project>/...                  live copy, exactly what's in the source
```

Inside HISTORY, each backup run that changed something creates a
timestamped snapshot holding the versions that were overwritten or
deleted (not a full copy — only the changes):

```
HISTORY/<project>/B-<date>/...        the changed/deleted files, that run
HISTORY/<project>/B-<date>.filelist   plain-text `find` listing of the snapshot
HISTORY/<project>/B-<date>.tar.gz     the snapshot, once archived (see below)
HISTORY/<project>/.bmulastrun         timestamp of the last successful run
```

`<date>` is `YYYYMMDD-HHMMSS`, so snapshot names sort chronologically as
plain strings. The index directory holds one full index of SYNC, one of
HISTORY, and one incremental index per backup run:

```
SYNC/.locate.dir/.locate.db                       full index of SYNC
SYNC/.locate.dir/.locate.dbb                       full index of HISTORY
SYNC/.locate.dir/.locate.db.<project>.<date>       one run's incremental index
```

Everything here is a plain file or directory — no bmug2-specific format
to read it back. If bmug2 disappeared tomorrow, the backup would still
be just `SYNC` (a normal copy of your data) plus `HISTORY` (old versions
you can `tar`/`grep`/`ls` into by hand).

## Install and configure

```
./bin/backmeup.install.sh
```

Copies the scripts to an install directory and runs
`backmeup.configure.sh`, which asks for the SYNC, HISTORY, index and
install directories, offers to create them, and detects a usable
`rsync` and `updatedb`/`locate`. Re-run `backmeup.configure.sh` alone
later to change settings — it preserves the previous
`backmeup.setup.sh` as `backmeup.setup.sh.old`.

Note: the install directory is *not* currently added to `PATH` (a
leftover `BMU_LINKTO` setting from the original bmu is defined but not
wired up yet) — call the scripts by full path, from the install
directory or straight from a clone, as in the Quick start above.

## Commands

### backmeup.sh

```
backmeup.sh [-n|--dry-run] <dir>
```

Backs up `<dir>` as a project named after its basename. Copies new and
changed files into `SYNC/<project>/`; anything changed or deleted since
the last run is moved into a new `HISTORY/<project>/B-<date>/` snapshot
instead of being lost. If nothing changed, no snapshot is created.

`-n`/`--dry-run` previews the transfer (what would be copied, deleted,
archived) without changing anything on disk — safety checks below still
run, so it also works as a pre-flight check.

Refuses to run (exit 1) when:
 - no usable rsync is found (only Apple's openrsync) — install a real one
 - the project's mirror is still in the old bmu layout — see
   [backmeup.migrate.sh](#backmeupmigratesh)

### backmeup.status.sh

```
backmeup.status.sh
```

One row per project in SYNC: last successful run, last archived change
(the newest snapshot, i.e. the last time a backup actually changed
something), snapshot count, and disk usage of the mirror and history.
Projects still in the old bmu layout are flagged with the exact
`backmeup.migrate.sh` command to fix them.

### backmeup.locate.sh

```
backmeup.locate.sh <pattern>...
```

Case-insensitive search across the current mirror and the full history
(`locate -i`), plus a plain-`grep` pass over the `.filelist` of any
*archived* snapshot (see [backmeup.archive.sh](#backmeuparchivesh)),
whose hits are marked `(archived)`. Works with no `locate` installed at
all — search then falls back entirely to the filelists.

### backmeup.updatedb.sh

```
backmeup.updatedb.sh
```

Rebuilds the full `SYNC` and `HISTORY` indexes from scratch and clears
old per-run incremental indexes. Can take a long time on a large
backup; a good candidate for a nightly cron job. Fails if no
`updatedb` is available.

### backmeup.archive.sh

```
backmeup.archive.sh [-n|--dry-run] <project> [days]
```

Compresses `HISTORY/<project>/B-<date>/` snapshots strictly older than
`days` (default 180, judged from the snapshot's own timestamp, not file
mtimes) into `B-<date>.tar.gz`, and removes the directory. The
`.filelist` is kept next to the tarball so the snapshot stays
searchable via `backmeup.locate.sh`. The directory is only removed
after verifying the tarball's entry count against it; on any failure
the snapshot is left untouched and the command exits 1.

`-n`/`--dry-run` lists what would be archived without changing
anything.

### backmeup.unarchive.sh

```
backmeup.unarchive.sh <project> <snapshot>
```

Exact inverse of archiving: extracts `<snapshot>.tar.gz` (accepts the
snapshot name with or without its `B-` prefix) back into
`HISTORY/<project>/`, then removes the tarball. Refuses to overwrite an
existing snapshot directory.

### backmeup.migrate.sh

```
backmeup.migrate.sh <project>
```

One-time fix for a project whose mirror is still in the original bmu
layout (`SYNC/<project>/<project>/` instead of `SYNC/<project>/`): an
instant, same-filesystem rename that preserves mtimes, so the next
`backmeup.sh` run transfers nothing. Refuses if the project directory
holds anything beyond the nested mirror, since that could also be a
correctly-laid-out project that legitimately contains a same-named
subdirectory — inspect manually in that case. Historical `B-<date>`
snapshots are untouched by design; they keep their own extra nesting
level and remain searchable as they are.

### Internal files, not meant to be run directly

`backmeup.setup.sh` (generated by configure) and
`backmeup.shellfunctions.sh` are sourced by the other scripts, not run
on their own. `backmeup.indexing.sh` is a stub for a planned
per-snapshot reindex command — currently unimplemented, it parses its
argument and exits without doing anything.

## Troubleshooting

**`ERROR: no usable rsync found`** — only Apple's openrsync is
installed; `brew install rsync` (or your distro's real rsync package).

**`ERROR: old bmu layout detected`** — run
[backmeup.migrate.sh](#backmeupmigratesh) for that project.

**`WARNING: no updatedb found, skipping indexing`** — backups still
work; install findutils to enable fast indexed search, or rely on
`backmeup.locate.sh`'s filelist fallback.

**A deleted file isn't in the mirror after `--delete`, but is it in
history?** — check `HISTORY/<project>/B-<date>/` for the most recent
snapshot (`backmeup.status.sh` shows the latest one), or
`backmeup.locate.sh <name>` to search across all of them at once.

**`glocate`/`locate` finds nothing, `gupdatedb`/`updatedb` prints
errors about paths that don't exist** — GNU findutils' `updatedb
--localpaths` treats its value as a **space-separated list of roots**,
by design. If SYNC or HISTORY themselves live under a path containing
a space (or, for a single run's incremental index, the project name
does), GNU `updatedb` cannot index them — this is a limitation of
GNU findutils, not something bmug2's own quoting can work around.
Backup, migrate, archive and the `.filelist`-grep fallback for archived
content are unaffected; only `locate`-backed search over such a path
is. Avoid spaces in the SYNC/HISTORY root paths if you rely on indexed
search.
