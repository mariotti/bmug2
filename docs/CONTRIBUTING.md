# Contributing

bmug2 is developed like any team project, even though today it has a
single maintainer:

1. Branch off an up-to-date `main` (`git checkout -b feature/<name>`).
2. Commit there, add or update tests under `tests/` for any behavior
   change, and keep `sh tests/test_backmeup.sh` green locally.
3. Push the branch and open a pull request (`gh pr create` or the
   GitHub UI).
4. Wait for CI: GitHub Actions runs four required jobs — the shell
   suite on Linux (rsync + plocate) and macOS (Homebrew rsync +
   findutils), and the `mcp/` pytest suite on both platforms too — all
   four must pass. Two more jobs, `gui-linux`/`gui-macos` (type-check +
   build the `gui/` frontend, then `cargo test` the Tauri backend), run
   on every PR too and should stay green, but aren't part of branch
   protection yet — a PR that only touches `bin/`/`mcp/` won't wait on
   them. (`gui-release.yml`, the packaging workflow that builds actual
   installers, is separate again: tag-triggered only, not run on PRs.)
5. Squash-merge the PR once it's reviewed. `main` is protected: direct
   pushes are rejected, and merging requires all four required checks
   green and the branch up to date with `main`.

The branch is deleted automatically on merge.

## Commit messages

Explain *why*, not just *what* — the diff already shows what changed.
Mention any bug found while testing and how it was confirmed, not just
the fix.

## Tests

New behavior needs a test that would fail without the change. The
suite (`tests/test_backmeup.sh`, using the bundled `shunit2`) replays
real backup scenarios in a temporary sandbox rather than mocking
`rsync`/`updatedb` — see existing tests for the pattern. The only
things faked are a stub `rsync`/`updatedb`/`tar` on `PATH` for testing
failure paths that are impractical to trigger for real (e.g. a full
disk), and scripted stdin for the interactive install/configure flow.

`mcp/` (the MCP server exposing bmug2 as LLM-callable tools) has its
own `pytest` suite under `mcp/tests`, following the same philosophy:
real sandboxes built through the actual `backmeup.install.sh`/
`configure.sh` (not the shell suite's sed-on-template shortcut, which
leaves unresolved shell syntax the Python config parser correctly
rejects), real subprocess calls, and a small subset that drives the
actual MCP stdio protocol rather than calling Python functions
directly. Run it with `pip install -e "./mcp[dev]" && pytest mcp/tests`.

`gui/` (the Tauri desktop app) has two suites, both under `gui/`: `cargo
test` for the Rust backend (`src-tauri/`) and `npm run test` (vitest)
for the TypeScript frontend (`src/`) - see `gui/README.md`'s own Test
section for exact commands, including coverage. Same real-over-mocked
preference as the other two suites where it's safe to: Rust tests spawn
real stub/real scripts against real sandboxed directories rather than
faking `Command::spawn`, and frontend tests mock only Tauri's
`invoke`/`listen` bridge (nothing in this repo can run a real native
window, so that boundary is unavoidable) while exercising the real
DOM-building and click-handling code around it. One real regression
this boundary let through: the Tauri command layer running blocking
subprocess work on the main thread and freezing the whole app - caught
only by hand-testing the real installed build, not by any test (see
`lib.rs`'s own comment above `run_backup_now` for the full story).
Known gap: the setup wizard, Settings screen, and Proton/Google
Drive folder-browser UI in `main.ts`, and the ~14 Tauri commands in
`lib.rs` that need an `AppHandle` (closing that needs either a
runtime-generic rewrite to use Tauri's `MockRuntime` test harness, or
confidence it wouldn't risk resolving `app_data_dir()` to a real
install's config under test).

### What the suite covers

One end-to-end test (`testUserJourneyEndToEnd`) drives a real install
through `backmeup.install.sh` with scripted answers, then runs the
full command set through the installed copy — this is the only test
touching `backmeup.install.sh`/`backmeup.configure.sh` at all, and it
exists because the two real bugs in `configure.sh` (fixed in commit
`ba62b8a`) were found by hand-testing, not by CI, since nothing
automated exercised that path before.

Everything else targets one command's behavior or edge case: the core
backup/mirror/history mechanics, each safety guard and refusal (no
usable rsync, old layout, missing updatedb, non-numeric archive age,
archiving/restoring a project or snapshot that doesn't exist), the
tar-failure safety net for archive/unarchive (verified by shadowing
`tar` on `PATH` with a stub that fails), and degraded-environment
behavior (no findutils at all, search still working via the
`.filelist` grep fallback).

Known, accepted gaps (not covered, and not expected to be): rare I/O
failures like a failed `mv`/`rmdir` mid-migration or a disk filling up
mid-`rsync`; the non-numeric-days validation is tested but the
tar-verification *count-mismatch* path (as opposed to `tar` outright
failing) is not, since faking a tarball with a plausible-but-wrong
entry count adds real complexity for the same code path already
covered by the failure case.

### Pre-release RPM smoke test (Lima)

Between an experimental tag (`vX.Y.Z-experimental`) and the plain
(`vX.Y.Z`) promotion, the `make test-rpm-*` targets install the
produced `.rpm` on real RPM-family distros via Lima VMs. One target
each for Fedora / Rocky / AlmaLinux, plus `test-rpm-all` to run all
three, and `test-rpm-clean` to tear down the VMs afterward. `make
help` prints the full list.

Smoke-tests the install path (`sudo rpm --import` → `sudo rpm
--checksig` → `sudo dnf install` → `rpm -V`), not GUI runtime — a
Lima VM is headless, so verifying the Tauri window actually opens
stays a manual pre-release step. Needs Lima (`brew install lima`)
and an authenticated `gh` CLI.

### Dependency audits

We run `npm audit` manually (not gated in CI) and act on every real
finding. Rust side: `cargo build` / `cargo clippy --all-targets --
-D warnings` are already gated in CI, so warnings there fail the
build at PR time; that's the entire Rust audit surface we care about.

Status tags for anything we're actively carrying (as opposed to
fixing today):

- **`known-upstream-pending`** — advisory exists, has a fix
  published somewhere upstream, but we can't resolve into it yet
  (typical shape: a transitive is pinned by a parent we don't
  control). Re-check on each upstream release of the parent chain.
- **`unmaintained-upstream`** — RUSTSEC-style informational
  advisory ("no active maintainer"). No fix version exists by
  design. Clears when the dependency chain switches to a maintained
  alternative.

Both are narrow carve-outs. The discipline for any OTHER audit
finding stays "fix in the same PR, not later" — see the "Fix every
warning in the same PR" paragraph in CLAUDE.md. These tags are not
a general "it's inconvenient so we'll ignore it" escape.

Historical note: the first entry we parked as
`known-upstream-pending` was `picomatch` ReDoS (GHSA-fc5q-39xc-vjpf),
reached via `vite`/`vitest`'s dev-only tree. Advisory was
**withdrawn by the upstream reviewer on 2026-11-18**, so there's
nothing left to park on the npm side; this paragraph stays only to
show what a withdrawal looks like (a clean exit, no code change
needed on our part).

`docs/DEPENDENCIES.md` carries the live, row-by-row list of direct
and transitive advisories with their status tags; this file owns the
*policy*, that one owns the *catalog*.

#### Expected CI redness: `Dependabot Updates`

GitHub's Dependabot Updates workflow runs on every push to `main`
and tries to open auto-fix PRs for alerts that have a patched
version available. It reports **`security_update_not_possible`**
and exits non-zero whenever a fix exists upstream but it can't
resolve any version satisfying the current dependency tree —
exactly what happens when a transitive we care about is pinned by
a parent we can't bump yet. That's a **permanent red X on `main`**
for as long as any such row stays `known-upstream-pending` in
`docs/DEPENDENCIES.md`.

This is the one documented exception to the project's "no red CI"
rule. The redness is honest — it's Dependabot telling us "I can't
auto-fix this" — but it's not actionable on our side until the
upstream pin moves. The alert itself stays open in the repo's
Security tab, and the workflow re-runs on every push; when upstream
publishes a release that frees the pin (e.g. a Tauri 2.x minor that
bumps gtk/muda/glib), Dependabot will succeed on the next push and
auto-open the fix PR.

What NOT to do in response to this failure:

- **Don't dismiss the alert** as "won't fix" — that silences the
  retry signal we actually want when upstream unpins.
- **Don't disable the workflow** — losing Dependabot would lose the
  always-on signal for *new* advisories too, not just this one.
- **Don't rerun it hoping for a different outcome** — the state
  machine is deterministic; `security_update_not_possible` will
  persist until the tree changes.

A real new failure class from this workflow (any error type other
than `security_update_not_possible`, or a `security_update_not_
possible` for a row NOT listed in `docs/DEPENDENCIES.md`) is an
actionable red that follows the regular "fix in the same PR"
discipline.
