# How should bmug2 run unattended?

bmug2 has no daemon, no built-in scheduler, and no generated cron/plist
file — it's a handful of self-contained scripts, and running them on a
timer is deliberately left to whatever your OS already gives you: cron,
`at`, systemd timers, or launchd. This doc covers all four, for both
Linux and macOS, plus what actually goes wrong when you wire one up.

**A note on how sure we are of each claim below.** Tier 1 is verified
the same way as the rest of this project: real commands, real output,
on this machine (macOS 26). Tier 2 is well-documented behavior of cron,
systemd, and launchd themselves — not independently re-tested here.
Tier 3 is flagged explicitly rather than asserted flatly: things that
vary by macOS release, by distro, or that would need a real Linux box
or a real TCC prompt to confirm.

## What every scheduler needs to know

The four sections below (cron, systemd timers, launchd, `at`) all rest
on the same handful of facts about bmug2 itself. Read this once,
skip straight to your platform after.

**1. Full paths — nothing gets sourced.** A scheduled job runs without
your shell's rc files, so `bmu` (the short dispatcher `install.sh`
offers to put on `PATH`) isn't reachable by name. Call
`backmeup.<subcommand>.sh` by its full install path instead. Current
working directory genuinely doesn't matter — every script resolves its
own location from `$0` before doing anything else
(`bin/backmeup.sh:8-18`) and sources `backmeup.setup.sh` from there —
but *how* you invoke it (a real path, not a bare name relying on
`PATH`) does.

**2. PATH inside the job is not your interactive PATH.** cron and
launchd both start jobs with a minimal `PATH` (typically just
`/usr/bin:/bin`), not the one your shell builds from
`.zshrc`/`.bash_profile`/Homebrew's shellenv. On a Homebrew-based
macOS, `rsync`, GNU `findutils` (`gupdatedb`/`glocate`), and `rclone`
all live under `/opt/homebrew/bin` (or `/usr/local/bin` on Intel) —
none of which is on that minimal PATH.

**This used to be the most common way a scheduled bmug2 job failed —
and worse, one shape of it failed silently rather than loudly.**
`backmeup.configure.sh` only runs its rsync/indexer/rclone detection
once, at configure time, and bakes the result verbatim into the
generated `backmeup.setup.sh`; nothing re-detects at backup/index/
replicate time. Older bmug2 versions baked in whatever bare command
name resolved at configure time (e.g. `BMU_CMDRSYNC="rsync"`) instead
of its resolved absolute path. Verified for real on this machine: a
normal interactive install baked in bare `rsync`; running that same
install's `backmeup.sh` from a minimal cron-like PATH afterward still
"worked" — bare `rsync` resolved via `/usr/bin`, but to **Apple's
openrsync**, a different binary than the Homebrew rsync used at
configure time. openrsync silently drops `--delete` when `--backup` is
active, so a deleted source file quietly stayed in the mirror forever,
with the run still reporting `exit 0` and no error at all. The
indexer/rclone side of the same bug failed *loudly* instead — bare
`gupdatedb`/`updatedb`/`rclone` simply weren't found under a stripped
PATH:

```
ERROR: no updatedb found, cannot build the index.
  Install GNU findutils (macOS: brew install findutils)
```

**Fixed**: `bmuDetectRsync()`, `bmuDetectIndexer()`, and the new
`bmuDetectRclone()` (all in `bin/backmeup.shellfunctions.sh`) now
resolve every match — bare or absolute-fallback — to its absolute path
via `command -v` before baking it in, so whatever binary was verified
at configure time is exactly what every future scheduled run executes,
regardless of what PATH looks like then. Confirmed for real, same
repro as above, both detection and the actual scheduled `--delete`
behavior now match under a minimal PATH.

**If you configured your install before this fix**, your existing
`backmeup.setup.sh` still has the old bare names baked in — re-run
`backmeup.configure.sh` once to pick up the absolute-path fix (it's
idempotent and safe to re-run; see
[Troubleshooting](MANUAL.md#troubleshooting) if `backmeup.sh` under a
scheduler still behaves oddly after that). Setting `PATH=` explicitly
in the scheduler entry (shown in every example below) still isn't a
bad habit regardless — it's just no longer the only thing standing
between you and the openrsync problem above.

**3. Order, and no lock.** Run backups first, `backmeup.updatedb.sh`
once after they've all finished, `backmeup.replicate.sh` last — the
same "replication only sees a finished tree" reasoning as
[DESTINATIONS.md](DESTINATIONS.md#what-to-do-instead-replicate-dont-mount).
bmug2 takes no lock of its own: cron will happily start a second
overlapping run if one job takes longer than the interval between
jobs; systemd and launchd units, in contrast, refuse to start a second
instance of a unit that's still running (Tier 2). If two cron jobs for
the *same* project could overlap on your schedule, stagger them
generously rather than relying on bmug2 to notice.

**4. Make failure visible.** A backup that silently stops running is
worse than one that never ran — it looks fine from a distance
(`backmeup.status.sh`'s LAST RUN column keeps ticking on old data).
Redirect or mail the job's output (cron's `MAILTO=`, systemd's journal,
launchd's `StandardOutPath`/`StandardErrorPath`), and check
`backmeup.status.sh` periodically regardless. rsync exit codes 23
("partial transfer") and 24 ("partial transfer due to vanished source
files") are worth recognizing specifically — 24 is often just files
that changed mid-scan (harmless), 23 is worth a look and, on macOS, is
also the shape a Full Disk Access denial takes (see below).

**5. A sleeping or off machine doesn't run cron.** If the job's
scheduled time comes and goes while the machine is asleep or shut down,
plain cron simply never runs it — there's no catch-up. Each platform
below has a different answer: systemd timers can mark themselves
`Persistent=true` (run once at next boot if a run was missed), launchd
generally catches up on wake for a job whose interval has passed (Tier
2 — not a hard guarantee), and `at` doesn't survive either case at all.

**6. Be nice.** `backmeup.updatedb.sh`'s own header documents a real
12m51s run against a large backup over Wi-Fi — indexing is the
heaviest job in the lineup. `nice`/`ionice` (Linux), systemd's `Nice=`
and `IOSchedulingClass=idle`, and launchd's `Nice` key are all cheap
insurance against a nightly reindex fighting you for the disk while
you're using the machine.

## Running more often than once a day

Nightly is the 80% case above, but "back up every few minutes so an
active editing session is never more than a few minutes from a copy"
is a real, common one too — someone writing a long document who can't
afford to lose an hour of work, for instance. All three mechanisms
support it; none of it needs a different tool.

**Cron** needs nothing new — the step syntax already documented in
`crontab(5)` just works: `*/5 * * * *` runs every 5 minutes,
`*/30 * * * *` every 30.

**launchd** uses a different key entirely, not just a different value
of `StartCalendarInterval`. `StartInterval <integer>` (seconds) fires
every N seconds instead — confirmed via `man launchd.plist` on this
machine:

> This optional key causes the job to be started every N seconds. If
> the system is asleep during the time of the next scheduled interval
> firing, that interval will be missed due to shortcomings in
> kqueue(3). If the job is running during an interval firing, that
> interval firing will likewise be missed.

That second sentence is worth reading twice: launchd itself guarantees
a `StartInterval` job never overlaps itself — a firing that lands while
the previous run is still going is simply skipped, not queued. Add
`StartInterval` (e.g. `1800` for every 30 minutes) to the LaunchAgent
plist below in place of `StartCalendarInterval`, nothing else changes.

**systemd timers** reuse the exact `OnCalendar=` directive daily
schedules already use, just with step syntax instead of a fixed
wall-clock time — `OnCalendar=*:0/5` for every 5 minutes. Verified for
real, same container technique as the daily unit files below:

```
$ systemd-analyze verify bmu-backup.service bmu-backup.timer
$ echo $?
0
$ systemd-analyze calendar --iterations=3 '*:0/5'
    Next elapse: Fri 2026-09-11 19:25:00 UTC
   Iteration #2: Fri 2026-09-11 19:30:00 UTC
   Iteration #3: Fri 2026-09-11 19:35:00 UTC
```

**Short intervals make the no-lock limitation (point 3 above) concretely
more likely to bite** — a 5-minute backup of a large folder can
genuinely still be running at the next firing. launchd handles this
gracefully on its own (confirmed above: it skips the overlapping
firing rather than starting a second copy). systemd's per-unit
activation semantics make a second concurrent start of the same
`Type=oneshot` service unlikely by default, but that's the safer Tier 2
assumption here, not independently re-verified against a real
long-running job on this machine — if you rely on very short intervals
for a large folder, watch `journalctl --user -u bmu-backup.service`
the first few times rather than assuming it's fine.

## Linux

### cron

The 80% answer, upgraded from the crontab in
[EXAMPLES.md](EXAMPLES.md#automating-it-cron-launchd-systemd-timers)
with an explicit `PATH` (point 2 above) and `MAILTO=` (point 4):

```
PATH=/usr/bin:/bin:/usr/local/bin
MAILTO=alex@example.com
# m h  dom mon dow   command
0  2   *   *   *     /home/alex/usr/bmu/bin/backmeup.sh /home/alex/Documents
5  2   *   *   *     /home/alex/usr/bmu/bin/backmeup.sh /home/alex/Pictures
30 2   *   *   *     /home/alex/usr/bmu/bin/backmeup.updatedb.sh
0  3   1   *   *     /home/alex/usr/bmu/bin/backmeup.archive.sh Documents
```

Edit with `crontab -e`, list with `crontab -l`. One gotcha specific to
bmug2's command lines (confirmed against `crontab(5)`): a bare `%` in a
cron command line means "newline, then feed the rest to the command's
stdin" — irrelevant for these command lines as written, but worth
knowing if you ever add a `date`-based suffix like `` `date +\%Y` `` —
escape it as `\%`.

### systemd timers

More visible than cron (`systemctl status`, `journalctl`, structured
failure state) and native catch-up support. A user-level unit pair —
no root needed, runs as you, in `~/.config/systemd/user/`:

`~/.config/systemd/user/bmu-backup.service`:

```ini
[Unit]
Description=bmug2 backup (Documents)

[Service]
Type=oneshot
Environment=PATH=/usr/bin:/bin:/usr/local/bin
ExecStart=/home/alex/usr/bmu/bin/backmeup.sh /home/alex/Documents
Nice=10
IOSchedulingClass=idle
```

`~/.config/systemd/user/bmu-backup.timer`:

```ini
[Unit]
Description=Run bmu-backup.service nightly

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

```
$ systemctl --user daemon-reload
$ systemctl --user enable --now bmu-backup.timer
$ systemctl --user list-timers
$ journalctl --user -u bmu-backup.service
```

A separate `.service`/`.timer` pair per subcommand (backup, updatedb,
archive) mirrors the cron layout above — stagger `OnCalendar=` times the
same way. User units stop when you log out unless you also run
`loginctl enable-linger $USER` once, so the timer keeps firing while
you're logged out (Tier 2).

Verified for real (this machine has no systemd of its own, so checked
inside an Ubuntu 24.04 container running systemd 255):

```
$ systemd-analyze verify bmu-backup.service bmu-backup.timer
$ echo $?
0
```

(the first check flags a missing `ExecStart` binary at the literal
example path, as expected since `/home/alex/...` doesn't exist in the
container — dropping in a stand-in executable there gets a clean,
error-free verification, confirming both unit files are syntactically
and semantically valid, not just plausible-looking.)

## macOS

### cron still works — with two caveats

`cron` is deprecated but still shipped (confirmed present:
`/System/Library/LaunchDaemons/com.vix.cron.plist` exists on this
machine, macOS 26). It works exactly as on Linux, with two macOS-only
catches:

- **The PATH gotcha above hits harder here** — rsync, GNU findutils,
  and rclone are *all* Homebrew installs on macOS, all under
  `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel),
  none on cron's default PATH. Set `PATH=` explicitly, same as above.
- **Full Disk Access.** See next section — it affects launchd too, but
  people hit it first via cron since it's the more familiar tool.

### Full Disk Access (TCC)

macOS's privacy framework (TCC) can silently block a background job
from reading `~/Documents`, `~/Desktop`, `~/Downloads`, or iCloud
Drive — the same directories the README's own quick start
(`bmu ~/Documents`) uses as its example — even though the identical
command works fine when you type it in Terminal (Terminal itself
already has Full Disk Access, or you granted it once and forgot).
The symptom is a per-file `rsync` failure (`Operation not permitted`),
often showing up as exit code 23 (point 4 above), not a clean "access
denied" for the whole run.

Fix: **System Settings → Privacy & Security → Full Disk Access**, add
`/usr/sbin/cron` (for cron jobs) — the actual binary needing access is
the one that executes your script, not your script itself. Test it
rather than assume it worked: schedule a run a couple of minutes out
and check the log, since **the exact list of what needs FDA, and
whether cron alone is enough versus also needing the shell or the
script's own path, has shifted across macOS releases and isn't
something to state flatly (Tier 3)**. Whether TCC also gates the
*destination* volume and not just the source is similarly unconfirmed
here.

### launchd

The native, macOS-preferred way to schedule a per-user job — a
LaunchAgent runs as you (correct file ownership for a personal backup;
a LaunchDaemon runs as root instead, which is both unnecessary here and
a worse starting point for the TCC prompt above, so LaunchAgent is the
right tool for this job, not LaunchDaemon).

`~/Library/LaunchAgents/local.bmu.backup.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.bmu.backup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/alex/usr/bmu/bin/backmeup.sh</string>
        <string>/Users/alex/Documents</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/alex/Library/Logs/bmu-backup.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/alex/Library/Logs/bmu-backup.log</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

```
$ plutil -lint local.bmu.backup.plist
local.bmu.backup.plist: OK
$ launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.bmu.backup.plist
$ launchctl kickstart -k gui/$(id -u)/local.bmu.backup   # run it right now
$ launchctl bootout gui/$(id -u)/local.bmu.backup        # unload it
```

(`plutil -lint` output above is from a real run against this exact
file on this machine — Tier 1. `launchctl bootstrap`/`bootout` is the
current form; older guides use `launchctl load -w`/`unload -w`, which
still works but is the deprecated spelling — Tier 2.)

**`ProgramArguments` execs the command directly — there is no shell in
between.** No `~` expansion, no `&&`, no pipes, no env-var
substitution beyond the `EnvironmentVariables` dict shown above. Use
full paths exactly as bmug2 already requires (point 1), and if you need
more than one command, point `ProgramArguments` at a small wrapper
script instead (see "Putting it together" below) rather than trying to
cram shell syntax into the array.

`StartCalendarInterval` runs on a wall-clock schedule like cron;
launchd generally makes up a missed run on wake if the machine was
asleep at the scheduled time (Tier 2, not a hard guarantee — test it if
it matters to you). A LaunchAgent only runs while a session is
active for that user; it does not run at the login window or make any
promises under FileVault's pre-boot lock screen (Tier 3 — behavior
here has also shifted across macOS versions).

## One-off runs: at

`at` is for a single future run, not a recurring schedule — "back this
up once before I unplug the drive tonight":

```
$ echo "/home/alex/usr/bmu/bin/backmeup.sh /home/alex/Documents" | at now + 2 hours
$ atq
$ atrm <job-number>
```

**macOS: `at` is installed but disabled by default.** Verified on this
machine — the launchd job that actually runs queued `at` jobs is
switched off out of the box:

```
$ plutil -p /System/Library/LaunchDaemons/com.apple.atrun.plist
{
  "Disabled" => true
  "Label" => "com.apple.atrun"
  "ProgramArguments" => [
    0 => "/usr/libexec/atrun"
  ]
  "StartInterval" => 30
}
```

Re-enabling it means unloading a System Integrity Protection-covered
daemon — not something to script casually. For a one-off run on macOS,
use `launchctl kickstart -k` against an already-loaded LaunchAgent
(above) instead, or just start the backup by hand.

**Linux: `at` needs `atd` running**, which minimal/container installs
often skip — check with `systemctl status atd` before relying on it. If
`atd` isn't available or you'd rather not add it, `systemd-run` gives
the same one-off semantics without a separate daemon:

```
$ systemd-run --user --on-active=2h /home/alex/usr/bmu/bin/backmeup.sh /home/alex/Documents
```

## "Any other scheduling"

A few things that exist but aren't covered in depth here:

- **Desktop cron front-ends** (GNOME's "Task Scheduler" GUIs, etc.) —
  they all just write a normal crontab underneath; the entries above
  work regardless of how you edit them in.
- **anacron** — runs a missed daily/weekly job on the next boot,
  roughly systemd's `Persistent=true` for classic cron; check whether
  your distro already wires `/etc/cron.daily` through it before adding
  your own entry there.
- **CI schedulers** (GitHub Actions `schedule:`, etc.) — not this
  project's problem; if you're backing up a CI runner's own state,
  treat it like any other Linux box above.
- **Trigger-based scheduling** — launchd's `StartOnMount`/`WatchPaths`,
  systemd `.path` units, udev rules: "back up the instant this drive is
  plugged in," rather than on a timer. Deliberately not given a recipe
  here yet — it interacts badly with bmug2 taking no lock (point 3
  above) if the same drive triggers a run while a timer-based one is
  already in flight, and that combination hasn't actually been tried
  against bmug2. Worth its own doc once it has.

## Putting it together

For more than a single command, write a small wrapper script and point
exactly one scheduler entry at it, rather than one entry per
subcommand:

```sh
#!/bin/sh
set -e
BMU=/home/alex/usr/bmu/bin
"$BMU/backmeup.sh" /home/alex/Documents
"$BMU/backmeup.sh" /home/alex/Pictures
"$BMU/backmeup.updatedb.sh"
"$BMU/backmeup.replicate.sh"
```

Make it executable, point cron/the `.service`/the LaunchAgent's
`ProgramArguments` at its full path, and the real exit code (thanks to
`set -e`) propagates to whichever scheduler is watching. bmug2
deliberately doesn't ship a wrapper like this itself — projects,
order, and how failures should be handled are yours to decide, not
something to bake into the tool.
