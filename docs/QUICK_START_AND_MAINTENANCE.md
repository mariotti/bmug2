# Quick start and maintenance

Everything on this page in one sitting is enough to run bmug2 well.
Each deeper doc it links to only matters once you actually hit the
situation it covers — you don't need to read them up front.

## Install

```
git clone https://github.com/mariotti/bmug2
cd bmug2
./install.sh
```

A few questions (SYNC/HISTORY/IndexDB directories, where the program
itself lives); accepting every default is fine for a first try. Prefer
a window over a terminal? [`gui/`](../gui/README.md) is a native app
that does the same install, plus a dashboard and per-folder scheduling
— everything below still applies either way, since the GUI just calls
these same commands underneath.

## Day one

```
bmu --dry-run ~/Documents       # preview - changes nothing
bmu ~/Documents                 # back it up for real
bmu locate report.pdf           # find it, current or historical
bmu status                      # see all projects at a glance
```

Repeat `bmu <dir>` for every folder you want backed up — there's no
registration step, each directory you point it at becomes its own
project. That's the whole workflow: run it, and it remembers every
version of everything that ever changed, forever, until you archive it.

## Make it automatic

Not required, but the point of a backup tool is not needing to remember
it. A crontab entry per project plus one reindex line covers most
setups:

```
0  2   *   *   *     /path/to/bin/backmeup.sh /Users/you/Documents
30 2   *   *   *     /path/to/bin/backmeup.updatedb.sh
```

Full paths only — cron doesn't know your shell's PATH. The GUI does
this without hand-writing cron/launchd/systemd syntax, per folder,
including running more often than daily for something you're actively
working on. Real recipes, the PATH gotcha, and per-platform specifics
(launchd, systemd timers, `at`): **[SCHEDULING.md](SCHEDULING.md)**.

## Ongoing maintenance

Once it's running, three things are worth a periodic look — none of
them urgent, none of them frequent:

- **`bmu status`** every so often. Confirms runs are actually
  happening (`LAST RUN` column) and gives a rough read on how much
  history each project has accumulated.
- **Archive old snapshots.** History grows forever by design — nothing
  deletes itself. `backmeup.archive.sh <project>` compresses snapshots
  older than 180 days (the default; pass a different number of days to
  change it) into one `.tar.gz`, still fully searchable, without
  needing the original directory kept around. There's no
  deduplication, so a large file that changes often is the main thing
  worth watching — see README's
  [Storage growth](../README.md#storage-growth) if disk use looks
  higher than expected.
- **Off-site replication**, if you set it up during install (or later
  via `backmeup.configure.sh`). `backmeup.replicate.sh` pushes SYNC and
  HISTORY to wherever you configured (S3, Drive, a remote host, …) —
  run it on the same cadence as your backups, right after them, so it's
  always pushing a finished, consistent tree. See
  [DESTINATIONS.md](DESTINATIONS.md) for why this is a separate step
  from the local backup itself, not the same destination.

## Upgrading

`./install.sh` again, from a freshly pulled/cloned checkout, over your
existing install — it now detects your real existing settings and
reuses them automatically (announced as `Found an existing install
at ...`), so pressing enter through every prompt refreshes the scripts
without touching your configuration. Full detail, and what happens if
something looks different than expected:
[MANUAL.md § Upgrading an existing install](MANUAL.md#upgrading-an-existing-install).

## If something looks wrong

Every error message bmug2 prints is deliberate and documented — see
[MANUAL.md § Troubleshooting](MANUAL.md#troubleshooting) for the exact
text and what it means. The two most common surprises:

- **A scheduled run behaves differently than running it by hand** —
  almost always PATH: cron/launchd don't have your interactive shell's
  PATH. See [SCHEDULING.md](SCHEDULING.md).
- **A file you expected to be backed up isn't there** — check whether
  it matches a `.gitignore`/`.bmuignore` pattern anywhere in that
  project's folder; see
  [EXAMPLES.md § respecting .gitignore and .bmuignore](EXAMPLES.md#special-setting-respecting-gitignore-and-bmuignore-per-project).

## Where everything else lives

This page is deliberately short. For anything it didn't cover:

- **[MANUAL.md](MANUAL.md)** — full command reference, directory
  layout, every flag, every troubleshooting entry.
- **[EXAMPLES.md](EXAMPLES.md)** — real worked sessions: multiple
  projects, excluding files, external drives, upgrading from the
  original bmu.
- **[DESTINATIONS.md](DESTINATIONS.md)** — where SYNC/HISTORY can
  actually live (local disks, cloud-sync folders, S3, multiple
  machines).
- **[SCHEDULING.md](SCHEDULING.md)** — cron, launchd, systemd timers,
  `at`, and the PATH gotcha that trips up most scheduled jobs.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — the development workflow, if
  you want to change bmug2 itself.
