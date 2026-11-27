# Getting started with bmug2

A one-page walkthrough aimed at a first-time tester. For depth —
every flag, every refusal, every tradeoff — see
[MANUAL.md](MANUAL.md). This doc is "install, back something up,
verify it's there, done."

## 1. Install (~2 minutes)

Grab the right package from [Releases](../../releases/latest) for
your OS. Table in [README.md](../README.md#install) lists all 7
artifacts; short version:

- **macOS (Apple Silicon)**: `bmug2_<version>_aarch64.dmg` → open,
  drag to Applications. First open: right-click → Open to bypass
  Gatekeeper.
- **Ubuntu / Debian**: `sudo apt install ./bmug2_<version>_amd64.deb`
- **Fedora / RHEL**: `sudo dnf install ./bmug2-<version>-1.x86_64.rpm`
  (GPG-signed; see [bmug2-releases.asc](bmug2-releases.asc) if your
  system complains).
- **Other Linux**: use the `.AppImage` — no install, `chmod +x` and
  run.

The GUI installer drops **both** the desktop app and the shell CLI.

## 2. First backup (~1 minute)

Open **bmug2.app** (or run `bmug2` in a terminal to launch the GUI).

On first launch bmug2 asks where to keep your data:

- **SYNC** = the live mirror. Treat as "a readable copy of your
  current folders". Default: `~/Backups/rsyncBackup`.
- **BackUp** (HISTORY) = timestamped snapshots of everything that
  changed or was deleted. Default: `~/Backups/rsyncBackup-BP`.
- **IndexDB** = the search index. Follows SYNC by default.

Accept the defaults unless you want them on a different drive.

Then: dashboard → **Add folder** → pick a small test folder
(something you can afford to lose, for a first run). The first
backup fires automatically — a progress log streams into the row.
Wait for "Last run" to turn green.

## 3. Verify it worked (~30 seconds)

**In Finder / your file manager**: navigate to
`~/Backups/rsyncBackup/<your-folder-name>/` — the files are there,
plain copies, no special format. Open one with any editor.

**In the GUI**: open **Disk usage** (dashboard header button). You
should see your folder listed with its size, and the new per-
project row carrying "SYNC" + "HISTORY" numbers.

## 4. Change a file, see the history kick in (~1 minute)

Edit a file in your source folder. Run **Run now** on that source
from the dashboard. Then look in
`~/Backups/rsyncBackup-BP/<folder>/`:

- `B-<timestamp>/` — the previous version of the file you changed.
- `.filelist` — a plain text index of what the snapshot contained.

That's it — bmug2 kept the old version. Edit-restore-any-file is
done with `backmeup.retrieve.sh` from the terminal (deliberately
CLI-only; GUI doesn't automate the one step that could clobber
in-progress work).

## 5. Schedule it (optional)

Dashboard → source row → **Set schedule** → pick Daily or Every N
minutes. bmug2 installs a real launchd (macOS) or systemd timer
(Linux). Runs continue even after you close the GUI.

**Important on macOS**: scheduled runs need Full Disk Access for
system folders like `~/Documents`. The dashboard shows a yellow
banner with the exact grants needed when it detects this.

## 6. Off-site replication (optional)

Dashboard → **HouseKeeping** → **Set schedule** (daily, after
every source's scheduled time — the dashboard warns if ordering
is off). Then **Off-site replication** → pick a backend:

- **rclone** — any rclone remote (Google Drive, S3, Backblaze, …).
- **pCloud** — via rclone (list + browse existing remote).
- **Proton Drive** — native E2EE, HISTORY only.
- **Mounted folder** — a desktop Drive (Dropbox, Google Drive File
  Provider, iCloud Drive, …). bmug2 auto-detects the usual mount
  paths; a hint shows which it found.

## Where to go next

- **[MANUAL.md](MANUAL.md)** — every command, every flag, every
  refusal. Required reading before pointing bmug2 at a large or
  irreplaceable dataset.
- **[DESTINATIONS.md](DESTINATIONS.md)** — tradeoffs between the
  four off-site backends.
- **[EXAMPLES.md](EXAMPLES.md)** — real-world use cases (thesis
  writer, photos, dotfiles, …) with the exact settings.
- **[SCHEDULING.md](SCHEDULING.md)** — scheduling details for
  macOS/Linux, including the Full Disk Access gotcha.
- **[PROJECT_disk-size.md](PROJECT_disk-size.md)** — how budgets +
  the one-click archive flow work, and why the shell layer never
  deletes.

## If something goes wrong

- bmug2 refuses to run a scheduled backup while a drive isn't
  mounted (silent "fills the system disk" is the worst possible
  failure for a backup tool, so the check is strict). If a backup
  stops running, check the drive is actually connected.
- Scheduled run didn't fire? macOS Full Disk Access is almost
  always the reason on a fresh install.
- Anything else: open a GitHub issue — the bug-report template
  asks for the details needed to reproduce.
