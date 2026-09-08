# bmug2 desktop GUI

A [Tauri](https://tauri.app) desktop app for [bmug2](../README.md):
native installers for macOS and Linux, a small Rust backend that shells
out to the real `backmeup.*.sh` scripts directly — no Python, no bundled
runtime, no logic reimplemented in a third language. `mcp/` (bmug2's
separate MCP server for LLM assistants) is untouched by this; the two
are independent consumers of the same core.

## Status

Skeleton only. The Rust↔JS bridge works (`bridge_check` command,
`npm run tauri dev` to see it), nothing else is built yet:

- No first-run setup screen — install bmug2 with `../install.sh` on the
  command line for now.
- No status dashboard or search UI — use `backmeup.status.sh`/
  `backmeup.locate.sh` (plain or `--json`, see `../docs/MANUAL.md`)
  directly.
- No packaging/release pipeline yet.

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
