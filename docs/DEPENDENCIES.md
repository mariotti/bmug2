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

Each row carries two security-oriented columns:

- **Tag** — a short first-pass classifier (see vocabulary below).
- **CVE (OSV)** — advisory count from [OSV.dev](https://osv.dev/)
  against the **currently installed version** (not the manifest
  range). Format: `active / historical`. "Active" = our installed
  version falls inside at least one `affected.ranges` interval.
  "Historical" = total advisories ever filed against the package
  on OSV; a non-zero historical with zero active means every past
  advisory has been patched in versions we've since moved past.

Tag vocabulary (first draft — expected to evolve):

- **`framework-core`** — the chosen architecture pillar. Replacing it
  is a rewrite, not a dep swap.
- **`vendor-coupled`** — part of Tauri's own ecosystem, maintained by
  the same org as `framework-core`. Moves in lockstep with the
  framework.
- **`well-known`** — widely-audited, mature library maintained by a
  recognized org or a battle-tested community.
- **`standard-toolchain`** — standard dev tool in its ecosystem's
  mainstream stack. Dev-time only (never shipped to users).

Future tags we'll likely need: `audit-pending` (a direct dep with
`active > 0` in the CVE column), `watch` (small / less-audited
library we want to revisit periodically), `vendored` (we carry the
source).

Transitive dependencies are tracked **only when they carry an active
advisory against the installed version** (see the "Transitive active
advisories" section near the bottom). A full transitive listing would
rot on every `npm update` / `cargo update`; the lockfiles already own
that catalog.

**CVE (OSV) last checked: 2026-11-20.** Regenerate with the one-liner
in "How to maintain this file" at the bottom (both direct and
transitive scans use the same OSV batch endpoint). Not automated —
a weekly or per-release manual run is the discipline.

GitHub's Dependabot alerts + security updates (L1 + L2) are also
enabled as the always-on signal; Dependabot's RustSec feed caught
`glib` in the transitive table below that an earlier macOS-only OSV
pass missed. The two scanners are complementary, not redundant.

## Rust (`gui/src-tauri/Cargo.toml`)

| Crate                   | Manifest version | First seen | Tag | CVE (OSV) | Notes |
|-------------------------|------------------|------------|-----|-----------|-------|
| `tauri`                 | `2`              | 2026-09-08 | `framework-core` — the app depends on it end-to-end; replacement = rewrite. | 0 / 9 | Framework. Provides the app runtime, IPC bridge (`#[tauri::command]`), and Tauri `AppHandle`/`WebviewWindow` APIs the GUI is built on. |
| `tauri-build`           | `2`              | 2026-09-08 | `vendor-coupled` — moves with `tauri`, same org. | 0 / 0 | Build-dependency that runs in `build.rs` to generate the Tauri scaffolding. Pairs with `tauri` — they move together. |
| `tauri-plugin-opener`   | `2`              | 2026-09-08 | `vendor-coupled` — Tauri-maintained plugin. | 0 / 0 | Backs the TS `revealItemInDir` / `openUrl` calls (Finder/Explorer reveal in search results; opening the macOS Privacy pane from the schedule panel). |
| `tauri-plugin-dialog`   | `2`              | 2026-09-09 | `vendor-coupled` — Tauri-maintained plugin. | 0 / 0 | Backs the TS `open({ directory: true })` native folder picker used in `buildReplicationEditor` (local path browse), the install setup form, and the per-source "add folder" flow. |
| `serde`                 | `1` (derive)     | 2026-09-08 | `well-known` — Rust's de-facto serialization crate; extensively audited. | 0 / 0 | Derives serde traits on every struct that crosses the IPC boundary (`ReplicationStatus`, `ReplicationRequest`, `BackupSource`, `Schedule`, `CloudMount`, …). Also powers config.json persistence. |
| `serde_json`            | `1`              | 2026-09-08 | `well-known` — same ecosystem and maturity as `serde`. | 0 / 0 | Reads/writes config.json; parses `rclone listremotes --json` / `lsjson` output in `rclone_browse.rs`; parses `backmeup.locate.sh --json` in `dashboard.rs`. |

## Node runtime (`gui/package.json` → `dependencies`)

| Package                       | Manifest version | First seen | Tag | CVE (OSV) | Notes |
|-------------------------------|------------------|------------|-----|-----------|-------|
| `@tauri-apps/api`             | `^2`             | 2026-09-08 | `vendor-coupled` — TS half of the Tauri framework. | 0 / 0 | TS counterpart of `tauri` — provides `invoke`, `listen`. Every Rust→TS call crosses this. |
| `@tauri-apps/plugin-dialog`   | `^2.7.3`         | 2026-09-09 | `vendor-coupled` — Tauri-maintained plugin. | 0 / 0 | TS counterpart of `tauri-plugin-dialog`. Exposes the native folder picker. |
| `@tauri-apps/plugin-opener`   | `^2`             | 2026-09-08 | `vendor-coupled` — Tauri-maintained plugin. | 0 / 0 | TS counterpart of `tauri-plugin-opener`. Exposes `revealItemInDir`, `openUrl`. |

## Node dev (`gui/package.json` → `devDependencies`)

| Package                       | Manifest version | First seen | Tag | CVE (OSV) | Notes |
|-------------------------------|------------------|------------|-----|-----------|-------|
| `@tauri-apps/cli`             | `^2`             | 2026-09-08 | `vendor-coupled` — Tauri's own CLI. | 0 / 1 | `tauri dev` / `tauri build` entry point; also drives the release workflow (`gui-release.yml`). |
| `@vitest/coverage-v8`         | `^5.0.4`         | 2026-10-15 | `standard-toolchain` — official vitest coverage provider; dev-time only. | 0 / 0 | V8-based coverage provider for vitest. Opt-in — `npm test` does not pass `--coverage`, so this only runs on demand (useful locally when inspecting what a given test exercises). |
| `jsdom`                       | `^30.0.1`        | 2026-09-13 | `well-known` — the standard JS-ecosystem DOM simulator; dev-time only. | 0 / 0 | DOM environment for vitest unit tests (`document`, `window`, `querySelector…`). All `*.test.ts` under `gui/src/` render DOM via this. |
| `typescript`                  | `~6.0.3`         | 2026-09-08 | `well-known` — Microsoft-maintained; dev-time only. | 0 / 0 | Compiler. Gated in CI via `tsc --noEmit`. |
| `vite`                        | `^8.0.16`        | 2026-09-08 | `standard-toolchain` — mainstream Vite.js project; dev-time only. | 0 / 29 | Dev server (`npm run dev`) + production bundler (`npm run build`). The Tauri app loads the built output in its webview. |
| `vitest`                      | `^5.0.0`         | 2026-09-13 | `standard-toolchain` — Vite-ecosystem test runner; dev-time only. | 0 / 3 | Unit test runner. 169 tests at the time of writing (see `gui/src/main.test.ts`). |

## Transitive active advisories

Filtered to transitive packages where the installed version falls
inside at least one `affected.ranges` interval. Direct deps are
already covered in the three tables above; this section is strictly
for transitives we're carrying through the lockfiles.

As of 2026-11-20 (441 Rust + 130 npm transitives scanned; full
cross-target — see the refresh snippet for the exact command, the
`--target all` flag matters on macOS where without it the Linux-only
subtree would be invisible).

| Package                            | Installed | Reached via                                    | Advisory                                           | Status  | Notes |
|------------------------------------|-----------|------------------------------------------------|----------------------------------------------------|---------|-------|
| `glib` (crates.io)                 | `0.18.5`  | `tauri` → `muda` → `gtk` 0.18 (Linux build only) | [GHSA-wrw7-89jp-8q8g](https://github.com/advisories/GHSA-wrw7-89jp-8q8g) / [RUSTSEC-2024-0429](https://rustsec.org/advisories/RUSTSEC-2024-0429) (unsoundness in `VariantStrIter` iterator impl) | `known-upstream-pending` | Patched upstream in `glib` 0.20.0, but the 0.18 line is pinned by Tauri 2.x's muda/gtk-rs transitive. We're on `tauri` 2.12.7 (latest stable, verified 2026-11-20); the 2.12.6/2.12.7 patch bumps didn't advance gtk/muda. Only `3.0.0-alpha.6` is newer. Linux-only. Re-check when Tauri 2.x updates muda/gtk, or when Tauri 3 ships stable. |
| `proc-macro-error` (crates.io)     | `1.0.4`   | `tauri` → `muda` → `gtk` → `glib-macros` (Linux-only) | [RUSTSEC-2024-0370](https://rustsec.org/advisories/RUSTSEC-2024-0370) (unmaintained) | `unmaintained-upstream` | Informational advisory: no active maintainer. No fix version by design. Reaches us via the same Linux GTK subtree as `glib`; moves with it. |
| `zbus_names` (crates.io)           | `4.3.5`   | `tauri-plugin-opener` → `zbus` (Linux only)    | [RUSTSEC-2026-0371](https://rustsec.org/advisories/RUSTSEC-2026-0371) (unmaintained) | `unmaintained-upstream` | Informational. Part of the `zbus` 5.x transitive carried by `tauri-plugin-opener` on Linux (D-Bus for `xdg-open`-style dispatch). `zbus` ecosystem split between maintained and unmaintained sub-crates; the opener plugin would need to switch to a maintained alternative, or absorb its own. |
| `zvariant` (crates.io)             | `5.15.1`  | `tauri-plugin-opener` → `zbus` (Linux only)    | [RUSTSEC-2026-0370](https://rustsec.org/advisories/RUSTSEC-2026-0370) (unmaintained) | `unmaintained-upstream` | Same chain / same rationale as `zbus_names`. |
| `zvariant_derive` (crates.io)      | `5.15.1`  | `tauri-plugin-opener` → `zbus` (Linux only)    | [RUSTSEC-2026-0372](https://rustsec.org/advisories/RUSTSEC-2026-0372) (unmaintained) | `unmaintained-upstream` | Same chain / same rationale as `zvariant`. |

When this table is empty the whole section still stays (empty table
beats "did they forget to check?").

Status values match the direct-dep Tag vocabulary, plus:

- **`known-upstream-pending`** — advisory exists, no fixed version
  published anywhere yet. Re-check on each upstream release.
- **`pending-bump`** — fixed version exists upstream; we just haven't
  bumped to it yet (should be rare — if a fix exists we take it).
- **`unmaintained-upstream`** — informational advisory (e.g. RUSTSEC
  publishes these to flag crates with no active maintainer); no fix
  version by design. Treated as "aware, not blocking" — not a known
  code-level vuln, just a maintenance signal. Clears when the chain
  switches to a maintained alternative or the dep absorbs its own.

## How to maintain this file

- When a direct dep is **added**, append a row with today's date, a **Tag** + short narrative, the **CVE (OSV)** result from a fresh query, and a one-line Note on what it's actually used for in this codebase.
- When a direct dep is **removed**, delete its row.
- When a direct dep is **bumped**, update the manifest version column if the range changed (`^1.2` → `^2`); don't rewrite every patch bump. Re-run the CVE query for that row.
- When an **advisory** lands (active > 0), retag to `audit-pending`, update the narrative, and cross-link `docs/CONTRIBUTING.md` → "Dependency audits".
- Transitive deps change on every `npm update` / `cargo update` and belong in the lockfiles, never here.

### Refreshing the CVE (OSV) data

One-off, no new tooling — just `curl` + `python3` against the public
OSV API. One script covers **both** jobs: (a) per-row active /
historical counts for the three direct-dep tables, and (b) the
transitive scan feeding the "Transitive active advisories" section.
Uses OSV's batch endpoint (`/v1/querybatch`, up to 1000 queries per
call), so the full 350-ish-package scan is one HTTP round trip.

```sh
python3 - <<'PY'
import json, subprocess, urllib.request
# --target all matters: without it, `cargo tree` on macOS silently
# omits the Linux-only subtree (gtk-rs / muda / glib etc. under
# tauri). An earlier pass without this flag reported "zero active
# advisories" while Dependabot's RustSec feed was flagging glib the
# whole time.
def rust_full():
    out = subprocess.check_output(['cargo','tree','--manifest-path','gui/src-tauri/Cargo.toml','--prefix','none','--no-dedupe','--target','all'], text=True)
    s=set()
    for line in out.splitlines():
        p=line.strip().split(' ')
        if len(p)>=2 and p[1].startswith('v'): s.add((p[0], p[1][1:]))
    return sorted(s)
def node_full():
    lock=json.load(open('gui/package-lock.json')); s=set()
    for k,v in lock['packages'].items():
        if not k.startswith('node_modules/') or 'version' not in v: continue
        name=k[len('node_modules/'):].split('/node_modules/')[-1]
        s.add((name, v['version']))
    return sorted(s)
def batch(queries):
    req=urllib.request.Request('https://api.osv.dev/v1/querybatch',
        data=json.dumps({'queries':queries}).encode(),
        headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=60) as r: return json.loads(r.read())['results']
# All transitives: version-filtered query returns ACTIVE advisories only.
rust, node = rust_full(), node_full()
q_active = [{'package':{'name':n,'ecosystem':'crates.io'},'version':v} for n,v in rust] \
         + [{'package':{'name':n,'ecosystem':'npm'},'version':v} for n,v in node]
res_active = batch(q_active)
# Direct deps: no version → OSV returns ALL historical advisories.
direct_r = ['tauri','tauri-build','tauri-plugin-opener','tauri-plugin-dialog','serde','serde_json']
direct_n = ['@tauri-apps/api','@tauri-apps/plugin-dialog','@tauri-apps/plugin-opener','@tauri-apps/cli','@vitest/coverage-v8','jsdom','typescript','vite','vitest']
q_hist = [{'package':{'name':n,'ecosystem':'crates.io'}} for n in direct_r] \
       + [{'package':{'name':n,'ecosystem':'npm'}} for n in direct_n]
res_hist = batch(q_hist)
# Report direct active/historical, and transitive active hits.
rust_iv = {n:v for n,v in rust}; node_iv = {n:v for n,v in node}
print('=== Direct CVE (active / historical) ===')
for n, r in zip(direct_r, res_hist[:len(direct_r)]):
    hist = len(r.get('vulns',[])); 
    aq = next((x for x in res_active if x['package']['name']==n and x['package']['ecosystem']=='crates.io'), None)
    act = sum(1 for _ in res_active[q_active.index(aq):q_active.index(aq)+1] for _ in _.get('vulns',[])) if aq else 0
    print(f"  {n} @ {rust_iv.get(n,'?')}  {act}/{hist}")
for n, r in zip(direct_n, res_hist[len(direct_r):]):
    hist = len(r.get('vulns',[]))
    aq = next((x for x in res_active if x['package']['name']==n and x['package']['ecosystem']=='npm'), None)
    act = sum(1 for _ in res_active[q_active.index(aq):q_active.index(aq)+1] for _ in _.get('vulns',[])) if aq else 0
    print(f"  {n} @ {node_iv.get(n,'?')}  {act}/{hist}")
print('=== Transitive active ===')
for q, r in zip(q_active, res_active):
    vs = r.get('vulns', [])
    if vs: print(f"  [{q['package']['ecosystem']}] {q['package']['name']}@{q['version']}: {[v['id'] for v in vs]}")
PY
```

After each run:

1. Update the **CVE (OSV)** counts in the three direct-dep tables.
2. Refresh the "Transitive active advisories" table (add / remove rows).
3. Update the **CVE (OSV) last checked** date at the top of the
   Security section.

The Tag column is a **first draft** — expect it to evolve as we hit
real cases they don't classify cleanly. Prefer refining the
vocabulary over stretching a tag to cover something it doesn't fit.
