# bmug2 desktop GUI

A [Tauri](https://tauri.app) desktop app for [bmug2](../README.md):
native installers for macOS and Linux, a small Rust backend that shells
out to the real `backmeup.*.sh` scripts directly — no Python, no bundled
runtime, no logic reimplemented in a third language. `mcp/` (bmug2's
separate MCP server for LLM assistants) is untouched by this; the two
are independent consumers of the same core.

## Status

On launch, the app checks a small config it owns
(`app_data_dir()/config.json` — it never auto-uses a discovered
install without an explicit click, matching `mcp/`'s "no single
well-known install location" stance):

- Nothing installed yet → a setup screen offers to download the latest
  bmug2 release and run its `install.sh` non-interactively
  (`gui/src-tauri/src/install.rs`), or point at a bin directory
  that's already set up — suggested from a bounded `find` scan of
  `$HOME` (`find_existing_installs`), or typed/pasted/browsed to
  directly. Either way, the install is checked against
  `gui/src-tauri/src/version.rs`'s `MIN_COMPATIBLE_VERSION` (reading the
  `BMU_VERSION` line in its `backmeup.setup.sh`) — an install that's too
  old, or predates `BMU_VERSION` entirely, is rejected with a clear
  message instead of failing confusingly once the dashboard tries to use
  it.
- Installed → a dashboard (`gui/src-tauri/src/dashboard.rs`): a
  per-project status table (`backmeup.status.sh --json`) with a
  Refresh button, and a search box (`backmeup.locate.sh --json`)
  tagging results by source (indexed vs. archived-snapshot fallback).
- **Backup Sources** (`gui/src-tauri/src/sources.rs`): a small
  GUI-owned list of folders to back up, persisted in `config.json` -
  bmug2 itself has no equivalent (`backmeup.sh <dir>` takes a
  directory argument each call and doesn't remember it, and
  `backmeup.status.sh` only reports projects already backed up at
  least once, with no record of their original source path). Add a
  folder via the native picker and its first backup runs immediately
  (the same **Run Now** path - `gui/src-tauri/src/run.rs`, a thin
  wrapper around `backmeup.sh` - rather than leaving a new, empty
  entry that needs a separate manual click); **Run Now** stays
  available afterward too, for backing up on demand anytime. Clicking
  it keeps the dashboard visible instead of taking over the whole
  screen: the button spins, an inline log under that source grows live
  (`backmeup.sh`'s already-verbose rsync output streamed line by line,
  the same mechanism Housekeeping's "Run now" uses below), and every
  other Run Now/Run now button disables itself meanwhile - jobs stay
  one-at-a-time dashboard-wide, since `backmeup.replicate.sh`/
  `backmeup.updatedb.sh` don't take a lock the way `backmeup.sh` itself
  does, so two actually running at once could read a file mid-write.
  The dashboard also cross-checks
  `backmeup.status.sh`'s project list against this: any project with
  real backup history that isn't a tracked Backup Source yet
  (typically backed up from the CLI before this app was installed)
  gets a notice offering to point it at its source folder and link it
  under its existing project name, rather than starting it over as a
  new one (`findUntrackedProjects`/`linkExistingProject` in
  `main.ts`) - projects still on bmug2's old pre-migration layout are
  excluded, since `backmeup.sh` refuses to run against those until
  `backmeup.migrate.sh` is run first (CLI-only). Each source also has
  an **Ignore settings** editor (`gui/src-tauri/src/ignore.rs`):
  toggle whether `.gitignore` is respected and whether `.bmuignore` is
  consulted (both default to `backmeup.sh`'s own CLI defaults - see
  `../docs/EXAMPLES.md`), plus a plain textarea over the raw
  `.bmuignore` file itself - deliberately just text, no filesystem
  browser.
- **Scheduling** (`gui/src-tauri/src/schedule.rs`): each Backup Source
  can independently get a real launchd (macOS) or systemd user timer
  (Linux) schedule - daily at a set time, or every N minutes for a
  fast-changing project (`config.rs`'s `Schedule` enum) - no plist/unit
  file to hand-write, matching the recipes in `../docs/SCHEDULING.md`.
  `updatedb`/`replicate` stay a separate, optional "Housekeeping"
  schedule (same daily-or-interval choice) rather than running on every
  source's own timer (avoids redundant reindexing when sources have
  different times) - a "Run now" button next to it (`run.rs`'s
  `run_housekeeping_now`, same stop-on-first-failure order as the
  installed schedule's own wrapper script) runs it on demand, whether
  or not a schedule is set, since configuring an off-site backend alone
  doesn't schedule anything - see docs/DESTINATIONS.md. Same
  non-blocking, live-streamed treatment as per-source Run Now above (a
  Tauri event per line, read from the child process as it's produced
  rather than buffered until exit) - a large first sync to a cloud
  remote can take a long time with the CLI's own default output giving
  nothing to show otherwise, which read as a hang in real use before
  this. The installed artifact is the source of truth for
  "is this actually scheduled" - `config.json`'s copy is just a UI
  mirror, self-corrected on load if it drifts. cron/`at` stay
  CLI-only; this only ever writes each platform's native, preferred
  mechanism.
- **Off-site replication** (`gui/src-tauri/src/replication.rs`):
  configure or clear any of three backends - `rclone` (mirrors
  SYNC+HISTORY to any remote), native Proton Drive (HISTORY only,
  end-to-end encrypted), or **Mounted folder** (Google Drive for
  Desktop, Dropbox, iCloud Drive, or any other cloud sync client that
  presents as a local directory — no OAuth, no rclone, just rsync into
  the mount; see docs/DESTINATIONS.md) - by shelling out to
  `backmeup.configure.sh`'s `--replicate-*` flags, the same
  non-reimplementing-the-CLI's-own-logic approach as install/scheduling.
  Requires bmug2 v2.14.0+ for the rclone and Proton backends; the
  Mounted folder backend additionally requires v2.18.7+ (it uses
  `--replicate-backend=local`, added in that release) and shows as
  disabled with an explanatory tooltip on older installs rather than
  locking out the whole panel. The Mounted folder fields are labelled
  "SYNC destination" and "BackUp destination"; on macOS, the panel
  auto-detects a Google Drive for Desktop mount at
  `~/Library/CloudStorage/GoogleDrive-*/My Drive` and pre-fills both
  paths (`<mount>/bmug2/SYNC` and `<mount>/bmug2/BackUp`) when both
  inputs are empty. An inline error fires if both paths are set to the
  same value before saving. Older installs (before v2.14.0) still show
  a disabled panel with an upgrade message rather than being locked out
  of the whole app — the CLI itself already fails loudly on an
  unrecognized flag, so no need to bump the GUI's blanket
  `MIN_COMPATIBLE_VERSION` for this optional feature. The
  Proton remote field has a "Browse…" button that opens an in-app
  folder picker (`gui/src-tauri/src/proton_browse.rs`), listing and
  creating folders via direct `proton-drive` CLI calls rather than a
  native OS dialog, since a cloud Drive's own tree isn't locally
  mounted. The button is disabled with an explanatory tooltip only if
  `proton-drive` isn't installed (checked via a read-only `filesystem
  info` call - never a cached guess) - not being signed in is no
  longer a reason to disable it. If the panel opens while signed out,
  it offers a "Sign in to Proton Drive…" button right there instead of
  a dead end: it runs `proton-drive auth login`, which opens the system
  browser itself and blocks until the user finishes signing in there
  (under a 5-minute timeout, since an abandoned browser tab would
  otherwise hang the GUI's "signing in…" state forever - Tauri has no
  way to cancel an in-flight command). A session that drops mid-browse
  (after a successful sign-in) still surfaces the same clear "run
  `proton-drive auth login`" message instead of a raw CLI error. The
  picker only ever lists (`filesystem list`) and creates
  (`filesystem create-folder`, checked first via `filesystem info` so
  it never collides with an existing node) - it never calls
  `trash`/`delete`/`move`/`rename`, so it cannot remove or overwrite
  anything already in the user's Drive. Both rclone remote fields
  (SYNC and HISTORY) have the same "Browse…" picker scoped specifically
  to configured Google Drive remotes (`gui/src-tauri/src/rclone_browse.rs`,
  filtering `rclone listremotes` to `type: "drive"` - not a general
  "browse any rclone remote" feature, since rclone's remote variety
  makes that a much less uniform operation). It lists via `rclone
  lsjson` and creates via `rclone mkdir` (already idempotent on its
  own) only - same no-`delete`/`move`/`rename` guarantee as the Proton
  picker. If more than one Google Drive remote is configured, the
  picker asks which one first; an expired/invalid token surfaces
  rclone's own actionable `rclone config reconnect <remote>:` message
  rather than a replaced generic one. If none is configured yet, the
  picker offers a "Connect Google Drive…" button right there instead of
  a dead end pointing at a terminal - it drives rclone's own
  non-interactive setup protocol (`rclone config create ...
  --non-interactive`, stepped via `rclone config update --continue`)
  end to end, with one exception it can't automate: answering
  "yes" to rclone's "use a web browser?" question makes rclone itself
  open the system browser and block waiting for the real Google
  sign-in, which stays a real human step the same as any legitimate
  "Connect your Google account" flow. Rejects a name that's already in
  use up front (`rclone config create` would otherwise silently
  overwrite an existing remote of the same name rather than erroring),
  and rolls back a broken, token-less stub via `rclone config delete`
  if the attempt fails or times out (5 minutes), so retrying under the
  same name afterward isn't blocked by its own safety check.
- **Settings / update check** (`gui/src-tauri/src/install.rs`'s
  `check_for_update`/`apply_update`): the dashboard does a best-effort
  check against GitHub's latest release once per app session (never
  blocks the dashboard or surfaces an error if offline) and shows a
  notice if a newer version exists. When the installed version is
  experimental (odd MINOR or odd PATCH — the project's own convention),
  the check also fetches pre-releases so you can see if a newer
  experimental exists, not just the latest stable. A dedicated Settings
  screen (reachable via a button next to the dashboard's title) shows
  installed vs. latest version — two rows when both a stable and an
  experimental update are available — and lets you trigger the same
  check manually, or install either update, always behind an explicit
  confirmation step, never automatic. Updating re-runs `install.sh`
  against the install's own existing sync/backup/index/install
  directories (never new ones, which would relocate rather than
  refresh it), the same non-reimplementing-the-CLI's-own-logic approach
  as install/replication above.

Still missing:

- No auto-staggering of overlapping per-source schedule times -
  visibility only (the dashboard lists already-scheduled times so you
  can self-stagger). `backmeup.sh` refuses a second overlapping run of
  the *same* project on its own (a per-project lock), so this is about
  wasted/failed runs from bad timing, not data corruption.
- No other mutating actions (archive/unarchive/migrate buttons) - use
  the CLI for those.
- No reconfigure/move-install UI — re-run `backmeup.configure.sh`
  directly for that, same as the CLI-only flow. Off-site replication
  and the Settings screen's update check (both above) are the two
  deliberate, narrowly-scoped exceptions — the former its own dedicated
  flags/panel, the latter refreshing the installed scripts in place
  (same directories, same settings) rather than reconfiguring anything.

## Disclaimer

See [../README.md's Disclaimer section](../README.md#disclaimer) for
the full risk notice. Two points are especially relevant to the GUI:

- **Run Now and scheduled runs are real, destructive rsync operations.**
  Every backup run (whether triggered by the Run Now button or a
  launchd/systemd schedule this app installs) calls `backmeup.sh`
  with `rsync --delete` — deletions in the source propagate to SYNC.
  There is no preview or dry-run step in the GUI before the run starts.
- **Installing a schedule means the backup runs automatically, without
  further confirmation.** Check the configured source paths and
  destination carefully before enabling a schedule.

## Why native Rust, not the `mcp/` Python server

Two backend options were considered: spawn `mcp/`'s existing MCP server
as a bundled sidecar and talk its stdio protocol, or call the shell
scripts directly from Rust. The sidecar route was rejected — it would
mean shipping a frozen Python runtime per platform (PyInstaller),
several tens of MB, for logic (`--json` output — see
`bin/backmeup.status.sh`/`bin/backmeup.locate.sh`) the shell scripts
now provide natively. Native Rust keeps this app to one toolchain and
`mcp/` completely out of its dependency chain.

## Requirements

- Rust (`rustc` ≥ 1.88 — Tauri 2's own dependency tree requires it;
  `rustup update` if `cargo check` complains about an older toolchain)
  and Node/npm.
- bmug2 itself installed somewhere (`../install.sh`) — this app has no
  logic of its own yet for backup/search, only for reaching bmug2's.
  See [../README.md#requirements](../README.md#requirements) for the
  full list of optional CLI tools (`rclone`, `proton-drive`,
  `findutils`) that unlock the corresponding panels in this app.

## Develop

```
cd gui
npm install
npm run tauri dev
```

`npm run tauri dev` uses your real, already-installed app's own config
(same `~/Library/Application Support/io.github.mariotti.bmug2/` the
packaged app uses) - handy for testing against real sources/schedules,
but it means `check_existing_install` always finds your real install
and skips straight to the dashboard.

To see the first-run/setup-wizard experience (an "empty system," no
saved install) without touching that real state at all, use
`npm run tauri:dev:isolated` instead - identical app, just running
under a separate identifier (`io.github.mariotti.bmug2.dev`, verified
for real: resolves to its own empty app-data directory, confirmed via
`tauri dev --config`'s documented merge behavior), so it always starts
from a clean slate. The window title says "bmug2 (isolated dev)" so
it's never confused with the real one.

`tauri:dev:isolated` merges `tauri.dev.conf.json` on top of the base
`tauri.conf.json`. Tauri's merge follows RFC 7396: **arrays are replaced
wholesale, not merged element-by-element**. The dev config's `app.windows`
array therefore replaces the base one entirely — any per-window key added
to the base config in the future must also be repeated in `tauri.dev.conf.json`
or the isolated session will silently drop it.

## Test

```
cd gui/src-tauri && cargo test && cargo clippy --all-targets
cd gui && npx tsc --noEmit && npm run test
```

Coverage (not gated in CI - these are local, point-in-time numbers to
track by eye, not a pass/fail threshold):

```
# Rust - needs cargo-llvm-cov + the llvm-tools-preview rustup component once:
rustup component add llvm-tools-preview
cargo install cargo-llvm-cov
cd gui/src-tauri && cargo llvm-cov --summary-only

# Frontend - needs @vitest/coverage-v8, already a devDependency:
cd gui && npx vitest run --coverage
```

See `../docs/CONTRIBUTING.md`'s Tests section for what each suite
covers and the known, deliberate gaps (both suites mock only Tauri's
`invoke`/`listen` bridge or AppHandle-dependent commands where real
end-to-end coverage isn't practical or safe here - never business
logic that's cheap and safe to exercise for real).

## Build

```
npm run tauri build
```

Produces a native app bundle under `src-tauri/target/release/bundle/`
(`.app`/`.dmg` on macOS, `.AppImage`/`.deb` on Linux — whichever
platform you build on; Tauri doesn't cross-compile installers).
