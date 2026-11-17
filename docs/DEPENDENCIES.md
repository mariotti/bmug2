# Dependencies

Direct dependencies only — the packages bmug2 explicitly declares in
`gui/src-tauri/Cargo.toml` and `gui/package.json`. Transitive deps are
not tracked here (the lockfiles are the source of truth for those).

Version shown is what the manifest asks for (semver range for npm,
exact or minor for Cargo). The actual installed version lives in the
lockfiles — intentionally not duplicated here so this file doesn't go
stale on every patch bump. See `docs/CONTRIBUTING.md` → "Dependency
audits" for the audit policy.

## Rust (`gui/src-tauri/Cargo.toml`)

| Crate                   | Manifest version | First seen | Notes |
|-------------------------|------------------|------------|-------|
| `tauri`                 | `2`              | 2026-09-08 | Framework. Provides the app runtime, IPC bridge (`#[tauri::command]`), and Tauri `AppHandle`/`WebviewWindow` APIs the GUI is built on. |
| `tauri-build`           | `2`              | 2026-09-08 | Build-dependency that runs in `build.rs` to generate the Tauri scaffolding. Pairs with `tauri` — they move together. |
| `tauri-plugin-opener`   | `2`              | 2026-09-08 | Backs the TS `revealItemInDir` / `openUrl` calls (Finder/Explorer reveal in search results; opening the macOS Privacy pane from the schedule panel). |
| `tauri-plugin-dialog`   | `2`              | 2026-09-09 | Backs the TS `open({ directory: true })` native folder picker used in `buildReplicationEditor` (local path browse), the install setup form, and the per-source "add folder" flow. |
| `serde`                 | `1` (derive)     | 2026-09-08 | Derives serde traits on every struct that crosses the IPC boundary (`ReplicationStatus`, `ReplicationRequest`, `BackupSource`, `Schedule`, `CloudMount`, …). Also powers config.json persistence. |
| `serde_json`            | `1`              | 2026-09-08 | Reads/writes config.json; parses `rclone listremotes --json` / `lsjson` output in `rclone_browse.rs`; parses `backmeup.locate.sh --json` in `dashboard.rs`. |

## Node runtime (`gui/package.json` → `dependencies`)

| Package                       | Manifest version | First seen | Notes |
|-------------------------------|------------------|------------|-------|
| `@tauri-apps/api`             | `^2`             | 2026-09-08 | TS counterpart of `tauri` — provides `invoke`, `listen`. Every Rust→TS call crosses this. |
| `@tauri-apps/plugin-dialog`   | `^2.7.3`         | 2026-09-09 | TS counterpart of `tauri-plugin-dialog`. Exposes the native folder picker. |
| `@tauri-apps/plugin-opener`   | `^2`             | 2026-09-08 | TS counterpart of `tauri-plugin-opener`. Exposes `revealItemInDir`, `openUrl`. |

## Node dev (`gui/package.json` → `devDependencies`)

| Package                       | Manifest version | First seen | Notes |
|-------------------------------|------------------|------------|-------|
| `@tauri-apps/cli`             | `^2`             | 2026-09-08 | `tauri dev` / `tauri build` entry point; also drives the release workflow (`gui-release.yml`). |
| `@vitest/coverage-v8`         | `^5.0.4`         | 2026-10-15 | V8-based coverage provider for vitest. Opt-in — `npm test` does not pass `--coverage`, so this only runs on demand (useful locally when inspecting what a given test exercises). |
| `jsdom`                       | `^30.0.1`        | 2026-09-13 | DOM environment for vitest unit tests (`document`, `window`, `querySelector…`). All `*.test.ts` under `gui/src/` render DOM via this. |
| `typescript`                  | `~6.0.3`         | 2026-09-08 | Compiler. Gated in CI via `tsc --noEmit`. |
| `vite`                        | `^8.0.16`        | 2026-09-08 | Dev server (`npm run dev`) + production bundler (`npm run build`). The Tauri app loads the built output in its webview. |
| `vitest`                      | `^5.0.0`         | 2026-09-13 | Unit test runner. 169 tests at the time of writing (see `gui/src/main.test.ts`). |

## How to maintain this file

- When a direct dep is **added**, append a row with today's date and a one-line Note on what it's actually used for in this codebase (not what the library claims to do in general).
- When a direct dep is **removed**, delete its row.
- When a direct dep is **bumped**, update the manifest version column if the range changed (`^1.2` → `^2`); don't rewrite every patch bump.
- Transitive deps change on every `npm update` / `cargo update` and belong in the lockfiles, never here.
