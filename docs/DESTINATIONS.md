# Where can SYNC and HISTORY live?

bmug2 has no idea what's mounted at `BMU_DIRRSYNC`/`BMU_DIRBACKUPS` — it
just points `rsync`, `find`, `tar` and `updatedb`/`locate` at whatever
path is there. That's both its whole strength (it works anywhere that
behaves like a normal filesystem) and the source of every limitation
below (things that don't behave like a normal filesystem cause real
trouble).

**A note on how sure we are of each claim below.** Everything about
bmug2's own behavior is verified the same way as the rest of this
project: real commands, real output, in the test suite or a sandbox.
Real cloud accounts and FUSE mounts are a different matter — this
machine has no Google Drive/Dropbox/AWS account configured, and
installing a kernel-level FUSE driver needs a human to click through a
macOS security prompt (and usually a restart), which isn't something
to do without asking. So Tier 1 is fully verified; Tier 2 is
well-documented behavior of Dropbox/Google Drive's own desktop clients,
not independently re-tested here; Tier 3's *problems* are demonstrated
for real (see below), and the *recommended alternative* is verified
with a real local sync run standing in for the cloud hop.

## Tier 1: real filesystems — what bmug2 is built for

Anything your OS mounts as an actual filesystem: the internal disk
(the default), an external USB/Thunderbolt drive, or a local network
mount (SMB, NFS, AFP — macOS ships `mount_smbfs`/`mount_afp` already).
This is the whole test suite's territory; nothing here is special-cased
by bmug2, it's just what a normal filesystem provides for free:
`rename()` for `--backup` to move a changed file into its snapshot
directory, real permissions and mtimes, and a directory tree `find`/
`locate` can walk directly.

Practical notes:

 - **Don't disconnect mid-run.** rsync isn't transactional across an
   entire backup — pulling a USB drive mid-transfer can leave a project
   partially updated. `backmeup.status.sh`'s LAST RUN vs. LAST CHANGE
   columns are a quick way to notice a run that didn't finish cleanly.
 - **SMB/NFS mounts** are still real filesystems, but mtime granularity
   and permission mapping across the network protocol can be
   approximate compared to a local disk — rarely a problem for bmug2's
   purposes (it doesn't rely on sub-second mtimes), worth knowing if
   something looks slightly off.
 - If the mount drops mid-run, `backmeup.sh` fails loudly (rsync
   errors, non-zero exit — see the exit-code fix in the CI history) —
   it doesn't silently write somewhere else.

## Tier 2: cloud-sync desktop folders (Dropbox, Google Drive, iCloud Drive)

Once the desktop client is installed, Dropbox/Google Drive/iCloud
Drive all present as an ordinary local folder (`~/Dropbox`, macOS's
`~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive`, or
`~/Library/Mobile Documents/com~apple~CloudDocs`). No FUSE, no special
mount — bmug2 can't tell it apart from any other directory, and in
principle just works.

In practice, worth knowing before you point `BMU_DIRRSYNC` there
(general knowledge about how these clients behave, not independently
tested in this environment):

 - **"Online-only" / "files on demand" features work against you.**
   Dropbox's Smart Sync and Google Drive's default streaming mode can
   leave files as placeholders that aren't actually on disk until
   opened. bmug2's `rsync`/`tar`/`locate` all need real bytes present —
   set the SYNC and HISTORY folders to "always keep on this device" (or
   the equivalent), not just for the files you back up but the backup
   destination itself.
 - **Every changed file becomes upload traffic.** After
   `backmeup.sh` runs, the sync client notices every touched file
   (including the ones freshly moved into a `B-<date>` snapshot) and
   re-uploads them. Fine for a personal Documents folder; worth a
   thought for anything large or frequently changing.
 - **One machine should own one SYNC/HISTORY pair.** bmug2 assumes it's
   the only writer. Running it from two machines against the same
   synced folder invites the cloud client's own conflict resolution
   (typically a renamed "(conflicted copy)" file) to collide with
   rsync's `--backup` renames. Pick one machine per backup destination.
 - Dotfiles (`.bmulastrun`, `.bmumeta`, `.locate.dir`) sync fine on
   current versions of these clients as far as is generally known —
   still worth a one-time check with `ls -la` on the destination side
   rather than assuming.

## Tier 3: object storage (S3) and FUSE-mounted cloud storage

This is the one to be honest about rather than optimistic: **S3 is not
a filesystem.** It's a flat key/value object store — there's no real
directory tree, no atomic rename, no POSIX permissions. Tools like
`s3fs`, `rclone mount`, and `gcsfuse` bridge this gap by *simulating* a
filesystem over the network, and the simulation has real, structural
costs that land squarely on bmug2's own usage pattern:

 - **Rename becomes copy + delete.** `--backup` moves each changed file
   into a timestamped snapshot directory — one real, cheap, atomic
   `rename()` on a normal filesystem. Over a FUSE object-store bridge,
   that's a full re-upload plus a delete, for every single file, every
   single run.
 - **Every stat, read, and write is a network round trip** — and,
   for S3 specifically, a billed API request. bmug2's snapshot
   directories are made of many small files by design (one entry per
   changed file); that's close to the worst case for both latency and
   cost on an object-store bridge.
 - **Getting there is itself real friction.** Confirmed while writing
   this doc: installing `rclone` fresh via Homebrew on macOS prints its
   own warning —

   ```
   $ brew install rclone
   ...
   Homebrew's installation does not include the `mount` subcommand
   on macOS which depends on FUSE, use `nfsmount` instead.
   ```

   Actually mounting anything (`rclone mount`, `s3fs`) needs a FUSE
   driver (macFUSE or FUSE-T), which means a macOS security approval
   and typically a restart — not something to reach for on a whim.

### What to do instead: replicate, don't mount

The pattern that actually plays to bmug2's strengths: let it run
against a real filesystem (Tier 1, or a Tier 2 folder), exactly as
designed, and add a **separate replication step** that copies the
*already-finished* backup tree to S3 (or Drive, or Dropbox) as an
off-site second copy. bmug2 never touches the cloud directly; a
purpose-built sync tool does that hop, and it's good at it in a way a
FUSE mount isn't — because it's transferring finished files once, not
simulating a live filesystem underneath rsync's rename-heavy workload.

Verified for real (standing in for a cloud remote with a second local
directory — the command is identical against a real remote, only the
destination argument changes):

```
$ rclone sync /Users/alex/Backups/rsyncBackup remote:my-bucket/rsyncBackup --progress
Transferred:   	        446 B / 446 B, 100%, 0 B/s, ETA -
Checks:                 0 / 0, -, Listed 20
Transferred:           10 / 10, 100%
Server Side Copies:    10 @ 446 B
Elapsed time:         0.0s
```

Run it again after a real bmug2 backup and only the changed file moves:

```
$ echo "changed again" >> ~/Backups/rsyncBackup/Documents/reports/summary.txt
$ rclone sync /Users/alex/Backups/rsyncBackup remote:my-bucket/rsyncBackup
```

`aws s3 sync` does the same job directly against S3 without `rclone` in
the middle, if you're already using the AWS CLI (flag names confirmed
against `aws s3 sync help` from a real install):

```
aws s3 sync ~/Backups/rsyncBackup s3://my-bucket/rsyncBackup --delete
aws s3 sync ~/Backups/rsyncBackup-BP s3://my-bucket/rsyncBackup-BP --delete
```

`--delete` mirrors deletions on the replica too, matching what you'd
generally want from an off-site *copy* of the backup rather than an
ever-growing pile.

A cron layout that puts this together — backmeup runs first, the cloud
replication only sees a finished, consistent tree:

```
0  2  *  *  *   /Users/alex/usr/bmu/bin/backmeup.sh /Users/alex/Documents
30 2  *  *  *   /Users/alex/usr/bmu/bin/backmeup.updatedb.sh
0  3  *  *  *   rclone sync /Users/alex/Backups/rsyncBackup remote:my-bucket/rsyncBackup
5  3  *  *  *   rclone sync /Users/alex/Backups/rsyncBackup-BP remote:my-bucket/rsyncBackup-BP
```

One more reason this pairs well with
[`backmeup.archive.sh`](EXAMPLES.md#housekeeping-status-and-archiving-old-snapshots):
object storage bills and performs by request/object count, and
`archive.sh` turns many small loose snapshot files into one `.tar.gz`
per old snapshot — fewer, larger objects for the replication step to
push, and cheaper to keep out there long-term.
