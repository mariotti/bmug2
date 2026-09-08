# bmug2 manual

Full command reference for bmug2. For what the project is and why, see
the [README](../README.md). For real usage recipes (multiple projects,
excluding files, cron, upgrading an old bmu disk), see
[EXAMPLES.md](EXAMPLES.md). For where SYNC/HISTORY can actually live
(local disks, cloud-sync folders, S3), see
[DESTINATIONS.md](DESTINATIONS.md).

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
   - [backmeup.replicate.sh](#backmeupreplicatesh)
   - [backmeup.migrate.sh](#backmeupmigratesh)
   - [bmu](#bmu)
 - [Shell completion (optional)](#shell-completion-optional)
 - [Troubleshooting](#troubleshooting)

## Directory layout

Three directories, set during configuration (defaults shown):

```
~/Backups/rsyncBackup              SYNC: the current mirror, one subdir per project
~/Backups/rsyncBackup-BP           HISTORY: old and deleted versions, per project
~/Backups/rsyncBackup/.locate.dir  the search index
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
./install.sh
```

(a thin wrapper around `bin/backmeup.install.sh`, kept at the repo
root so a fresh clone doesn't need to know where it actually lives)

Copies the scripts to an install directory and runs
`backmeup.configure.sh`, which asks for the SYNC, HISTORY, index and
install directories, offers to create them, and detects a usable
`rsync` and `updatedb`/`locate`. Along the way it explains what each
question is for: SYNC/HISTORY/IndexDB are your **data**, and should
live somewhere safe from casual deletion — but SYNC and IndexDB in
particular are meant to stay readily available, so a local disk (even
the internal one) is often the right call, not necessarily an external
drive or NAS. An off-site copy is a separate replication step layered
on top, not a replacement destination for these — see
[DESTINATIONS.md](DESTINATIONS.md). The two install-location questions
are a different thing entirely: where the **program** itself lives,
which should stay on your regular system disk. The generated `backmeup.setup.sh` also
carries a short comment explaining what it is, since it's meant to be
sourced by the other scripts, not run directly. Re-run
`backmeup.configure.sh` alone later to change settings — it preserves
the previous `backmeup.setup.sh` as `backmeup.setup.sh.old`.

`backmeup.configure.sh` also generates `${BMU_INSTDIR}/backmeup_shrc` —
a small, pure-POSIX-sh file that puts the install directory's `bin/` on
`PATH` (idempotent: safe to source more than once). At the end of
`install.sh`, you're offered (y/N, never done silently) to add one line
sourcing it to your shell rc file (`~/.zshrc`, `~/.bash_profile`/
`~/.bashrc`, or `~/.profile`, detected from `$SHELL`). Decline and you
can still call every script by full path, from the install directory or
straight from a clone; add the line yourself later if you change your
mind — the exact line to add is shown either way. `backmeup_shrc` is
regenerated on every `backmeup.configure.sh` run, so if you ever move
`BMU_INSTDIR` you'll need to re-run `install.sh` (or manually update the
line in your rc file) to point at the new location — this one-time
recheck isn't automatic. A leftover `BMU_LINKTO` setting from the
original bmu is still defined but unused; `backmeup_shrc` is the
supported way to get bmug2 onto `PATH` now.

If `rclone` is installed, configuration also offers (optional, y/N) to
set up off-site replication — see
[backmeup.replicate.sh](#backmeupreplicatesh).

**Non-interactive**: every prompt above has a matching flag —
`--sync-dir=`, `--backup-dir=`, `--index-dir=`, `--install-path=`,
`--install-dir=` — for a scripted or GUI caller with no terminal to
prompt on. Flags and prompts can mix: any question without a matching
flag still prompts interactively. Passing any flag switches the whole
run non-interactive, including auto-skipping the optional replication
setup above (re-run interactively later to enable it). `install.sh`
forwards its own arguments straight through to `backmeup.configure.sh`,
so the flags work the same way at either entry point:

```
./install.sh --sync-dir=/mnt/backup/sync --backup-dir=/mnt/backup/sync-BP \
    --index-dir=/mnt/backup/sync/.locate.dir \
    --install-path="$HOME/usr" --install-dir="$HOME/usr/bmu"
```

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

`--json` emits the same data as one JSON object instead of the table —
`{"sync_dir", "history_dir", "projects": [{"name", "last_run",
"last_change", "snapshot_count", "mirror_size_kb", "history_size_kb",
"old_layout"}, ...]}` — for a GUI or any other non-terminal consumer.
`*_size_kb` comes from `du -sk` (block-based kilobytes, not an exact
byte sum — portable across BSD/GNU `du`, close enough for a dashboard
number). `last_run`/`last_change` are `null` when a project has none
yet, otherwise the same raw internal date strings used elsewhere
(`YYYY-MM-DD HH:MM:SS` and `YYYYMMDD-HHMMSS` respectively — not
reformatted to match each other or ISO 8601).

### backmeup.locate.sh

```
backmeup.locate.sh <pattern>...
```

Case-insensitive search across the current mirror and the full history
(`locate -i`), plus a plain-`grep` pass over the `.filelist` of any
*archived* snapshot (see [backmeup.archive.sh](#backmeuparchivesh)),
whose hits are marked `(archived)`. Works with no `locate` installed at
all — search then falls back entirely to the filelists.

`--json` emits `{"patterns", "indexed", "counts": {"index",
"archived_filelist"}, "results": [{"path", "source"}, ...]}` instead of
plain-text lines — `source` is `"index"` or `"archived_filelist"`;
`indexed` is `false` when no `locate` binary is available (results can
then only come from the archived-filelist fallback).

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

### backmeup.replicate.sh

```
backmeup.replicate.sh [-n|--dry-run]
```

Copies the whole SYNC and HISTORY trees to an off-site destination via
`rclone sync` — the actual backup disk (external drive, NAS, cloud;
see [DESTINATIONS.md](DESTINATIONS.md)), layered on top of the local
versioning above, not a replacement for it. Run it as often as you can
tolerate losing — the gap between replication runs is how much work a
local-disk failure could cost, not a fixed "nightly is enough" default.

`-n`/`--dry-run` previews what would be copied without changing the
destination.

Refuses to run (exit 1) when:
 - replication hasn't been configured — re-run `backmeup.configure.sh`
   (only offered if `rclone` is installed)

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

### bmu

```
bmu <dir>                        # shorthand for: bmu backup <dir>
bmu [-n|--dry-run] backup <dir>
bmu status
bmu locate <pattern>...
bmu archive <project> [days]
bmu unarchive <project> <snapshot>
bmu migrate <project>
bmu updatedb
```

A short dispatcher, available once bmug2 is on your `PATH` (see
[Install and configure](#install-and-configure) above), that routes to
the matching `backmeup.*.sh` command — `bmu status` is
`backmeup.status.sh`, `bmu locate report.pdf` is
`backmeup.locate.sh report.pdf`, and so on. `bmu` does no argument
validation of its own; each subcommand's underlying script owns that,
so behavior (including every error message) is identical either way —
`bmu` is purely a shorter way to type the same thing.

Anything that isn't a recognized subcommand — including a bare
directory, or `-n`/`--dry-run` — falls through to the backup shorthand.
This means `bmu status` can't mean "back up a directory literally named
`status`" (the same trade-off `git status` makes for a directory named
`status`); use `bmu backup ./status` or `backmeup.sh ./status` directly
in that case.

### Internal files, not meant to be run directly

`backmeup.setup.sh` (generated by configure) and
`backmeup.shellfunctions.sh` are sourced by the other scripts, not run
on their own. `backmeup.indexing.sh` is a stub for a planned
per-snapshot reindex command — currently unimplemented, it parses its
argument and exits without doing anything.

## Shell completion (optional)

Tab-completion for `bmu`'s subcommand names (not project names —
completing those would mean a completion script re-locating and
sourcing `backmeup.setup.sh` on every keypress, which needs to stay
fast and can't assume the backup disk is even connected; a documented
future enhancement, not implemented today). Not wired up automatically
by `backmeup_shrc` or `install.sh` — activating it touches
shell-specific completion machinery (`fpath`, `compinit`) that's a
bigger, more collision-prone ask than "add one line to PATH."

**bash** — add to your shell rc file, after the `backmeup_shrc` line:

```
. "${BMU_INSTDIR}/bin/bmu-completion.bash"
```

**zsh** — add the install `bin/` directory to your `fpath` *before*
calling `compinit` (the completion file is named `_bmu`, which zsh's
completion system requires):

```
fpath=("${BMU_INSTDIR}/bin" $fpath)
autoload -U compinit && compinit
```

## Troubleshooting

**`ERROR: no usable rsync found`** — only Apple's openrsync is
installed; `brew install rsync` (or your distro's real rsync package).

**`ERROR: old bmu layout detected`** — run
[backmeup.migrate.sh](#backmeupmigratesh) for that project.

**`WARNING: no updatedb found, skipping indexing`** — backups still
work; install findutils to enable fast indexed search, or rely on
`backmeup.locate.sh`'s filelist fallback.

**`ERROR: replication is not configured`** — re-run
`backmeup.configure.sh` and accept the off-site replication prompt
(needs `rclone` installed first if it wasn't offered).

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
