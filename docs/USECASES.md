# What is bmug2 for?

This document states the *intent* behind bmug2 — what it optimises
for, who it fits, and what it deliberately does not try to be. It is
positioning, not a feature list: read it to understand which
direction a change should pull, and which "missing" features are
missing on purpose. When a proposed feature conflicts with the core
promise below, the promise wins.

## The core promise: plain and durable

bmug2 exists to give you a **version history of your files that you
will still be able to read years from now, with no bmug2 involved.**

The destination is a plain rsync mirror plus timestamped snapshots.
There is no encryption, no password, no database, no proprietary
container, nothing to remember and nothing to keep working. In twenty
years, with whatever `ls`, `cp`, `tar` and `grep` exist then, the
backup is still fully usable. That longevity — not speed, not
cleverness — is the whole point. Every design choice is subordinate to
"can a stranger with standard Unix tools still get the data out,
decades later, knowing nothing about this project."

This is always true of the primary SYNC/HISTORY copy. The one
deliberate exception is off-site replication to Proton Drive
(`backmeup.replicate.proton.sh`): Proton's own client end-to-end
encrypts that copy, which is a genuine, opt-in reason to choose it
specifically for an off-site replica (see
[docs/DESTINATIONS.md](DESTINATIONS.md#proton-drive-as-a-replication-target)).
That's a property of Proton Drive, not of bmug2's own format — the
primary copy stays plain either way — but it does mean "no password,
nothing to remember" isn't universally true of *every* copy an
off-site-replicating user ends up with.

## What bmug2 is *not* for

Stating the non-goals plainly, because they look like gaps if you
assume bmug2 is a conventional backup tool:

- **It is not disaster recovery.** Rebuilding a machine after a disk
  crash is a situation-specific job — which disk, which OS, which
  parts survived — and bmug2 intentionally does not try to automate
  it. Recovering from a crash is a dedicated, manual approach chosen
  to fit the crash; bmug2's role is only to have kept a plain,
  readable copy you can draw from.
- **It is not push-button, in-place restore.** There is no command
  that repopulates your original tree. That is a non-goal, not a
  TODO.
- **It is not an encrypted or compliance vault.** Plainness is the
  feature for the primary copy; if the threat model requires
  encryption at rest *there*, this is the wrong tool. The Proton Drive
  off-site option (above) is a named exception for a replica, not a
  general encryption feature to build a compliance story on.

Keeping these out is the honest position. A tool that promised
bare-metal restore and quietly failed at it would be worse than one
that says clearly: I keep a durable, readable history; putting it back
is your call, suited to the situation.

## How restore fits that purpose

Because the goal is durability rather than recovery speed, `retrieve`
is a **safe extraction primitive, not a restoration command.** It
pulls a single file or a whole snapshot — from a live or an archived
(`.tar.gz`) snapshot alike — out to a destination *you* name. It never
overwrites, and never touches the SYNC mirror or the HISTORY store.
Making a file "live" again in its original place is a deliberate `cp`
you perform.

This is exactly the right shape for the most common real recovery
event (see the thesis case): "I changed this file and want
yesterday's version back," read-only and non-destructive. It is the
wrong shape for "rebuild my system" — which is the non-goal above.

## Who bmug2 fits

The ideal user wants *a systematic, plain, durable version history*
more than they want fast catastrophe recovery, and has data that is:

- **Low-churn** — documents, source, records; not constantly-rewritten
  multi-gigabyte files.
- **Long-lived and worth reading later** — things where plain format
  and longevity matter more than restore speed.
- **Modest in size** — so keeping deep history is cheap.

## Worked example: backing up a thesis

A good, concrete fit. Someone writing a thesis wants frequent local
backups — say every 30 minutes — plus a roughly one-day guarantee
that a copy also sits off-site in the cloud.

Why this fits bmug2 specifically:

- **The real recovery event here is "give me yesterday's draft of
  this section," not "my disk died."** That is precisely the
  read-only, extract-to-a-safe-place operation `retrieve` is built
  for. The catastrophic case is covered by the cloud copy, so the
  absence of disk-crash automation does not bite.
- **A thesis is small and low-churn.** Each 30-minute snapshot's
  churn is tiny, backups where nothing changed are near-free (bmug2
  no-ops on an unchanged run), and a *full year* of 30-minute history
  is still almost nothing on disk. Retention effectively stops being a
  problem — you can keep every snapshot for the life of the thesis
  with no eviction.

Mapping the request onto the two existing tiers:

- **Local backup every 30 minutes** → ~30-minute RPO for the
  "undo my edits" case (a timer firing the normal backup run).
- **Daily replication to the cloud** → ~1-day off-site RPO for the
  "laptop lost, stolen or destroyed" case. Via `rclone` this mirrors
  SYNC+HISTORY (live tree and snapshots both); via the native Proton
  Drive backend it's HISTORY only - a narrower but still sufficient
  slice for a thesis, since the snapshots already capture everything
  the live tree currently holds.

Three honest caveats to set expectations with a user like this:

1. **RPO is "last save," not "last keystroke."** A 30-minute timer
   captures what is on disk; the editor's unsaved buffer is not
   included.
2. **Open files.** Editor lock/temp files get picked up as noise, and
   a backup firing mid-save can catch a half-written file — usually
   harmless at 30-minute granularity (the next snapshot is clean).
   Exclude the editor's lock/temp patterns via `.bmuignore`.
3. **The one-day cloud guarantee is best-effort on a laptop.** If the
   machine is asleep, offline or on battery when the daily push is
   due, that run is skipped — so the guarantee holds only while the
   machine is online daily. Per-destination `status` ("remote last
   ok: 6h ago") is what makes the guarantee *visible* rather than
   assumed.

## Other good fits

The same shape — longevity-first, low-churn, version-history —
fits more than theses:

- Writers and researchers who do not use git but want dated,
  readable copies of their work.
- Personal or legal records where plain, unlocked format matters more
  than restore speed.
- Anyone who wants a systematic history of dated copies without
  trusting a format they will have to keep readable themselves.

## Poor fits (point them elsewhere)

- Needing automated bare-metal or whole-system recovery → a
  dedicated imaging/backup tool.
- Large, high-churn datasets (VMs, databases, media libraries under
  constant change) → tools built around deduplication and that
  workload.
- Encryption-at-rest or regulatory requirements for the *primary*
  copy → an encrypting backup tool; plainness is the wrong property
  there. (Proton Drive replication covers only an off-site replica,
  not the primary SYNC/HISTORY copy, and isn't a compliance feature.)
