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
  folder via the native picker, then **Run Now**
  (`gui/src-tauri/src/run.rs`, a thin wrapper around `backmeup.sh`)
  to back it up on demand.

Still missing:

- No scheduling UI (cron/launchd/systemd-timer setup) - see
  `../docs/SCHEDULING.md` for the manual/CLI recipe in the meantime;
  a GUI equivalent is a planned follow-up.
- No other mutating actions (archive/unarchive/migrate buttons,
  or on-demand `updatedb`/`replicate`) - use the CLI for those.
- No reconfigure/move-install UI — re-run `backmeup.configure.sh`
  directly for that, same as the CLI-only flow.

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

## Develop

```
cd gui
npm install
npm run tauri dev
```

## Build

```
npm run tauri build
```

Produces a native app bundle under `src-tauri/target/release/bundle/`
(`.app`/`.dmg` on macOS, `.AppImage`/`.deb` on Linux — whichever
platform you build on; Tauri doesn't cross-compile installers).
