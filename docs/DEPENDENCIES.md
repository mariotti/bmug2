# Dependencies

Direct dependencies only — the packages bmug2 explicitly declares in
`gui/src-tauri/Cargo.toml` and `gui/package.json`. Transitive deps are
not tracked here (the lockfiles are the source of truth for those).

Version shown is what the manifest asks for (semver range for npm,
exact or minor for Cargo). The actual installed version lives in the
lockfiles — intentionally not duplicated here so this file doesn't go
stale on every patch bump. See `docs/CONTRIBUTING.md` → "Dependency
audits" for the audit policy.

## Security posture

Each row carries a **Security** column: a short tag plus a one-sentence
narrative. The tag is a first-pass classifier — expected to be
refined as we learn more (e.g. folding advisory status in, splitting
the "watch" bucket by cause). First draft; not the final shape.

Tag vocabulary:

- **`framework-core`** — the chosen architecture pillar. Replacing it
  is a rewrite, not a dep swap. Scrutinize changes carefully; trust
  built up over releases is our only real defense.
- **`vendor-coupled`** — part of Tauri's own ecosystem, maintained by
  the same org as `framework-core`. Moves in lockstep with the
  framework; its security posture is effectively Tauri's.
- **`well-known`** — widely-audited, mature library maintained by a
  recognized org or a battle-tested community. Mainstream enough
  that an advisory would move through the ecosystem fast.
- **`standard-toolchain`** — standard dev tool in its ecosystem's
  mainstream stack. Dev-time only (never shipped to users), so
  advisories carry a different (lower) blast radius.

Future tags we'll likely need: `audit-pending` (a direct dep with an
open-upstream advisory), `watch` (small / less-audited library we
want to revisit periodically), `vendored` (we carry the source).

Transitive-only advisories (like picomatch's GHSA-fc5q-39xc-vjpf
reaching us through `vite`/`vitest`) are tracked in
`docs/CONTRIBUTING.md` → "Dependency audits", not here — a direct
dep's tag only reflects risk the dep *itself* carries.

## Rust (`gui/src-tauri/Cargo.toml`)

| Crate                   | Manifest version | First seen | Security | Notes |
|-------------------------|------------------|------------|----------|-------|
| `tauri`                 | `2`              | 2026-09-08 | `framework-core` — the app depends on it end-to-end; replacement = rewrite. | Framework. Provides the app runtime, IPC bridge (`#[tauri::command]`), and Tauri `AppHandle`/`WebviewWindow` APIs the GUI is built on. |
| `tauri-build`           | `2`              | 2026-09-08 | `vendor-coupled` — moves with `tauri`, same org. | Build-dependency that runs in `build.rs` to generate the Tauri scaffolding. Pairs with `tauri` — they move together. |
| `tauri-plugin-opener`   | `2`              | 2026-09-08 | `vendor-coupled` — Tauri-maintained plugin. | Backs the TS `revealItemInDir` / `openUrl` calls (Finder/Explorer reveal in search results; opening the macOS Privacy pane from the schedule panel). |
| `tauri-plugin-dialog`   | `2`              | 2026-09-09 | `vendor-coupled` — Tauri-maintained plugin. | Backs the TS `open({ directory: true })` native folder picker used in `buildReplicationEditor` (local path browse), the install setup form, and the per-source "add folder" flow. |
| `serde`                 | `1` (derive)     | 2026-09-08 | `well-known` — Rust's de-facto serialization crate; extensively audited. | Derives serde traits on every struct that crosses the IPC boundary (`ReplicationStatus`, `ReplicationRequest`, `BackupSource`, `Schedule`, `CloudMount`, …). Also powers config.json persistence. |
| `serde_json`            | `1`              | 2026-09-08 | `well-known` — same ecosystem and maturity as `serde`. | Reads/writes config.json; parses `rclone listremotes --json` / `lsjson` output in `rclone_browse.rs`; parses `backmeup.locate.sh --json` in `dashboard.rs`. |

## Node runtime (`gui/package.json` → `dependencies`)

| Package                       | Manifest version | First seen | Security | Notes |
|-------------------------------|------------------|------------|----------|-------|
| `@tauri-apps/api`             | `^2`             | 2026-09-08 | `vendor-coupled` — TS half of the Tauri framework. | TS counterpart of `tauri` — provides `invoke`, `listen`. Every Rust→TS call crosses this. |
| `@tauri-apps/plugin-dialog`   | `^2.7.3`         | 2026-09-09 | `vendor-coupled` — Tauri-maintained plugin. | TS counterpart of `tauri-plugin-dialog`. Exposes the native folder picker. |
| `@tauri-apps/plugin-opener`   | `^2`             | 2026-09-08 | `vendor-coupled` — Tauri-maintained plugin. | TS counterpart of `tauri-plugin-opener`. Exposes `revealItemInDir`, `openUrl`. |

## Node dev (`gui/package.json` → `devDependencies`)

| Package                       | Manifest version | First seen | Security | Notes |
|-------------------------------|------------------|------------|----------|-------|
| `@tauri-apps/cli`             | `^2`             | 2026-09-08 | `vendor-coupled` — Tauri's own CLI. | `tauri dev` / `tauri build` entry point; also drives the release workflow (`gui-release.yml`). |
| `@vitest/coverage-v8`         | `^5.0.4`         | 2026-10-15 | `standard-toolchain` — official vitest coverage provider; dev-time only. | V8-based coverage provider for vitest. Opt-in — `npm test` does not pass `--coverage`, so this only runs on demand (useful locally when inspecting what a given test exercises). |
| `jsdom`                       | `^30.0.1`        | 2026-09-13 | `well-known` — the standard JS-ecosystem DOM simulator; dev-time only. | DOM environment for vitest unit tests (`document`, `window`, `querySelector…`). All `*.test.ts` under `gui/src/` render DOM via this. |
| `typescript`                  | `~6.0.3`         | 2026-09-08 | `well-known` — Microsoft-maintained; dev-time only. | Compiler. Gated in CI via `tsc --noEmit`. |
| `vite`                        | `^8.0.16`        | 2026-09-08 | `standard-toolchain` — mainstream Vite.js project; dev-time only. See the `docs/CONTRIBUTING.md` audit note on picomatch (transitive, not direct). | Dev server (`npm run dev`) + production bundler (`npm run build`). The Tauri app loads the built output in its webview. |
| `vitest`                      | `^5.0.0`         | 2026-09-13 | `standard-toolchain` — Vite-ecosystem test runner; dev-time only. Same transitive-picomatch footnote as `vite`. | Unit test runner. 169 tests at the time of writing (see `gui/src/main.test.ts`). |

## How to maintain this file

- When a direct dep is **added**, append a row with today's date, a **Security** tag + one-sentence narrative, and a one-line Note on what it's actually used for in this codebase (not what the library claims to do in general).
- When a direct dep is **removed**, delete its row.
- When a direct dep is **bumped**, update the manifest version column if the range changed (`^1.2` → `^2`); don't rewrite every patch bump. Revisit the Security tag only if the dep's posture has actually changed (e.g. it absorbed a merged advisory, or it's now orphaned).
- When an **advisory** affects a direct dep, retag it (`audit-pending` or similar), update the narrative, and cross-link `docs/CONTRIBUTING.md` → "Dependency audits".
- Transitive deps change on every `npm update` / `cargo update` and belong in the lockfiles, never here.

The Security tags are a **first draft** — expect them to evolve as we hit real cases they don't classify cleanly. Prefer refining the vocabulary over stretching a tag to cover something it doesn't fit.
