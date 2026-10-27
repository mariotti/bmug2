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

### Shell coverage badge

The `linux-coverage` CI job measures line coverage of `bin/*.sh` and
updates the badge in the `badges` branch. It uses bashcov (a Ruby gem;
Ruby is pre-installed on the GitHub runner). Because the scripts use
`#!/bin/sh` — which on Ubuntu 24.04 is `dash`, not traceable by
bashcov's DEBUG-trap mechanism — the coverage job temporarily redirects
`/bin/sh → bash` before running. The correctness test (`linux` job) still
runs under real sh/dash; this job only measures which lines execute.

The badge is **not** a required check and only updates on pushes to
`main`. Coverage is scoped to `bin/` via a `.simplecov` filter created
in the runner at runtime (not checked in). To run locally:

```sh
gem install bashcov --no-document
sudo ln -sf /usr/bin/bash /bin/sh   # Linux only
cat > .simplecov << 'EOF'
SimpleCov.configure do
  add_filter { |f| !f.filename.include?('/bin/') }
end
EOF
bashcov -- bash tests/test_backmeup.sh
# result: coverage/.last_run.json
```
