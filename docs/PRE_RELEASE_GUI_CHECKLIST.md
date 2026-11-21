# Pre-release GUI checklist

A hand-driven walkthrough of each top-level user journey, run against
a locally-built binary **before** promoting an experimental tag to
stable (`vX.Y.Z-experimental` → `vX.Y.Z`). Pairs with `docs/
CONTRIBUTING.md`'s "Pre-release RPM smoke test (Lima)" — that one
covers installability, this one covers runtime.

Why this exists: unit + integration tests (shell / cargo / vitest)
cover logic but not visual regressions or runtime interactions a
headless CI can't see (cursor focus, form reset after save, panel
layout at different window sizes, native dialogs actually opening,
revealed items actually revealing). This is the one manual gate.

## Setup

```sh
cd gui
npm run tauri dev
```

Wait for the window to load. Keep the DevTools console open — any
Rust panic or TS exception lands there in dev mode.

Work through the sections below in order. Not every box has to be
re-ticked each release — mark a row N/A with a note if a journey
didn't change since the last stable (and nothing it touches did
either).

## Journey 1 — Fresh install (new install setup wizard)

Delete or rename your existing `~/Library/Application Support/<app
bundle id>/config.json` so the app starts in first-run mode.

- [ ] First window shows the setup wizard (not the dashboard).
- [ ] "Install a new copy" tab shows default paths pre-filled.
- [ ] Each Browse button opens a native OS folder picker.
- [ ] Picking a non-default SYNC path auto-updates the IndexDB
  default to a sibling.
- [ ] Submit installs without error; the window flips to the
  dashboard.
- [ ] Existing install path (second tab) accepts an already-
  configured `/bin` directory from another checkout and reaches the
  dashboard.

## Journey 2 — Add source + first run

- [ ] "Add folder" button opens the native folder picker.
- [ ] A new source appears in the Sources table with the correct
  path and name.
- [ ] The first `backmeup.sh` run fires immediately after Add (new
  source is auto-run — don't need a separate Run Now click).
- [ ] Progress log streams live into the row (not a full-screen
  spinner). Row's "Last run" column updates on success.

## Journey 3 — Scheduled run

- [ ] "Set schedule" opens the editor row.
- [ ] Daily picker + "Every N minutes" preset both save cleanly.
- [ ] The scheduled job actually fires (wait for the next tick, or
  use `launchctl kickstart` on macOS / `systemctl --user start` on
  Linux). Last-run column advances.
- [ ] Turning a schedule off removes the launchd plist / systemd
  timer (`launchctl list | grep bmug2` / `systemctl --user list-
  timers | grep bmug2` returns empty).
- [ ] macOS only: Full Disk Access banner shows **four grants**
  (bmug2.app, rsync OR /bin/sh — the new copy from #211), with the
  `+` + Cmd+Shift+G hint and a working Open-Settings button.

## Journey 4 — Retrieve (CLI-only)

bmug2 has no GUI restore flow by design — this one's a terminal
check:

- [ ] `backmeup.retrieve.sh <project> <B-stamp> <dest>` restores a
  whole snapshot (both live and archived variants).
- [ ] Single-file retrieve works for both.
- [ ] Refuses to overwrite an existing destination.

## Journey 5 — Unarchive (CLI-only)

- [ ] `backmeup.unarchive.sh <project> <B-stamp>` restores a `.tar.
  gz` and a `.tar` (media-kind) back into history. Both lose their
  archive after success.

## Journey 6 — Replicate off-site

Run through each backend end-to-end (not just the editor save):

- [ ] **rclone**: Save + a real `backmeup.replicate.sh` run against
  a configured Google Drive remote pushes SYNC + HISTORY. Browse
  button lists remotes; Create folder button creates one.
- [ ] **pCloud**: Backend dropdown offers it. Browser lists pcloud
  remotes. The "no remote configured yet" screen points at
  `rclone config` without a Connect button (intentional — see F3
  in `docs/REVIEW_*.md` / `buildPcloudFolderBrowser` module comment).
- [ ] **Proton Drive**: Browser authenticates, lists `/my-files`,
  New folder creation works, a real replicate push succeeds.
- [ ] **Mounted folder** (Google Drive / Dropbox / iCloud / pCloud
  native / OneDrive / Box): Browse opens native OS picker.
  "Detected cloud folders" hint shows every provider present under
  `~/Library/CloudStorage/` and `~/pCloudDrive`. Local SYNC / BackUp
  destinations save and replicate successfully.
- [ ] After save, the status line reads back the correct backend
  name (regression guard: pcloud previously round-tripped as rclone
  before the dedicated backend split).

## Journey 7 — Upgrade via Settings

- [ ] Settings screen shows the current installed version.
- [ ] If an update is available (fake one by hand-editing the
  version marker to an old number), the "Install" button appears
  for stable and/or experimental.
- [ ] Clicking Install shows the confirmation screen, not an
  immediate action.
- [ ] Confirm actually downloads + re-runs `install.sh`, re-reads
  the version, and lands on an updated dashboard.

## Journey 8 — Disk usage view

- [ ] "Disk usage" button in the dashboard header navigates to the
  new screen.
- [ ] Four headline numbers render with help-icons.
- [ ] Per-source table shows every tracked source with a size (or
  an em-dash + hint if a path can't be read).
- [ ] Per-project table shows every live project in SYNC with
  SYNC / HISTORY / Off-site status columns.
- [ ] Projects with `replicate_class=none` render as `Local-only`
  and the Replicate estimate excludes them.
- [ ] Back button returns to the dashboard.

## Journey 9 — Per-source toggles

For a tracked source, exercise each toggle in the always-visible
row:

- [ ] `.gitignore` respect toggle saves.
- [ ] `.bmuignore` respect toggle saves.
- [ ] `.bmuignore` editor opens, text saves, next backup run honors
  new patterns.
- [ ] Replicate class dropdown saves; "Local-only" projects are
  excluded from the next `backmeup.replicate.sh` run (verify by
  checking the replicate log).
- [ ] Source kind dropdown saves; a "Media" source archives as
  `.tar` (not `.tar.gz`) on the next `backmeup.archive.sh` run.

## After the walkthrough

- [ ] No red lines in the DevTools console that weren't there
  before (ignore known Tauri dev-mode warnings; a real TS exception
  or Rust panic is a blocker).
- [ ] `git status` in the repo clean (dev mode sometimes regenerates
  resource files; commit them separately if so).
- [ ] If any row failed: do **not** cut the stable tag. Either fix
  in a follow-up PR against the experimental cut, or document the
  gap on the release and keep it as experimental.

Delete this file — never. Keep it; update it when a new journey
lands (e.g. if pcloud Connect flow comes online, add it under
Journey 6; if GUI restore ever gets built, swap Journey 4/5 from
CLI-only to GUI-driven).
