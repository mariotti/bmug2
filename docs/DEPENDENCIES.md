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

Transitive-only advisories (like picomatch's GHSA-fc5q-39xc-vjpf
reaching us through `vite`/`vitest`) are tracked in
`docs/CONTRIBUTING.md` → "Dependency audits", not here.

**CVE (OSV) last checked: 2026-11-17.** Regenerate with the one-liner
in "How to maintain this file" at the bottom. Not automated — a
weekly or per-release manual run is the discipline.

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
| `vite`                        | `^8.0.16`        | 2026-09-08 | `standard-toolchain` — mainstream Vite.js project; dev-time only. See the `docs/CONTRIBUTING.md` audit note on picomatch (transitive, not direct). | 0 / 29 | Dev server (`npm run dev`) + production bundler (`npm run build`). The Tauri app loads the built output in its webview. |
| `vitest`                      | `^5.0.0`         | 2026-09-13 | `standard-toolchain` — Vite-ecosystem test runner; dev-time only. Same transitive-picomatch footnote as `vite`. | 0 / 3 | Unit test runner. 169 tests at the time of writing (see `gui/src/main.test.ts`). |

## How to maintain this file

- When a direct dep is **added**, append a row with today's date, a **Tag** + short narrative, the **CVE (OSV)** result from a fresh query, and a one-line Note on what it's actually used for in this codebase.
- When a direct dep is **removed**, delete its row.
- When a direct dep is **bumped**, update the manifest version column if the range changed (`^1.2` → `^2`); don't rewrite every patch bump. Re-run the CVE query for that row.
- When an **advisory** lands (active > 0), retag to `audit-pending`, update the narrative, and cross-link `docs/CONTRIBUTING.md` → "Dependency audits".
- Transitive deps change on every `npm update` / `cargo update` and belong in the lockfiles, never here.

### Refreshing the CVE (OSV) column

One-off, no new tooling — just `curl` + `python3` against the public
OSV API. Resolves the installed version from the lockfiles (not the
manifest range) and matches it against each advisory's affected
version ranges:

```sh
python3 - <<'PY'
import json, subprocess, urllib.request, re
def ver(s):
    m = re.match(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?', s)
    return tuple(int(x or 0) for x in m.groups()) if m else None
def rust():
    out = subprocess.check_output(['cargo','tree','--manifest-path','gui/src-tauri/Cargo.toml','--depth','1','--prefix','none'], text=True)
    return {p[0]: p[1][1:] for line in out.splitlines() if (p:=line.strip().split(' ')) and len(p)>=2 and p[1].startswith('v')}
def node():
    pkg, lock = json.load(open('gui/package.json')), json.load(open('gui/package-lock.json'))
    names = list(pkg.get('dependencies',{}).keys()) + list(pkg.get('devDependencies',{}).keys())
    return {n: lock['packages'].get(f'node_modules/{n}',{}).get('version','?') for n in names}
def osv(name, eco):
    r = urllib.request.Request('https://api.osv.dev/v1/query',
        data=json.dumps({'package':{'name':name,'ecosystem':eco}}).encode(),
        headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(r, timeout=15) as x: return json.loads(x.read()).get('vulns',[])
def active(iv, ranges):
    iv = ver(iv)
    if not iv: return False
    for r in ranges:
        cur = False
        for e in r.get('events',[]):
            if 'introduced' in e: t=ver(e['introduced']); cur = (t is None or iv>=t)
            if 'fixed' in e: t=ver(e['fixed']); cur = cur and not (t and iv>=t)
            if 'last_affected' in e: t=ver(e['last_affected']); cur = cur and not (t and iv>t)
        if cur: return True
    return False
def row(name, eco, iv):
    vs = osv(name, eco); a = sum(1 for v in vs for aff in v.get('affected',[])
        if aff.get('package',{}).get('name','').lower()==name.lower() and active(iv, aff.get('ranges',[])))
    return (len(vs), a)
r, n = rust(), node()
for nm in ['tauri','tauri-build','tauri-plugin-opener','tauri-plugin-dialog','serde','serde_json']:
    t,a = row(nm,'crates.io', r.get(nm,'?')); print(f"{nm} @ {r.get(nm)}  {a}/{t}")
for nm in ['@tauri-apps/api','@tauri-apps/plugin-dialog','@tauri-apps/plugin-opener','@tauri-apps/cli','@vitest/coverage-v8','jsdom','typescript','vite','vitest']:
    t,a = row(nm,'npm', n.get(nm,'?')); print(f"{nm} @ {n.get(nm)}  {a}/{t}")
PY
```

Update the "CVE (OSV) last checked" date at the top of this file
after each run.

The Tag column is a **first draft** — expect it to evolve as we hit
real cases they don't classify cleanly. Prefer refining the
vocabulary over stretching a tag to cover something it doesn't fit.
