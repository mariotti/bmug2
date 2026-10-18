# CLAUDE.md

Project-specific procedures for Claude Code sessions on bmug2. This is
a recipe book for the mechanical release/branch pipeline - the
codebase itself, versioning *policy*, and test philosophy are
documented in `README.md`/`docs/CONTRIBUTING.md`; don't duplicate
those here, just the exact commands.

## Branch/PR/merge cycle (every change, no exceptions)

1. `git checkout main && git pull --ff-only origin main` before
   branching anything new.
2. `git checkout -b <type>/<short-name>` - prefixes used so far:
   `fix/`, `gui/`, `docs/`, `chore/version-X.Y.Z`.
3. Run the full verification suite **before** committing:
   - `bash tests/test_backmeup.sh`
   - `cd gui/src-tauri && cargo test && cargo clippy --all-targets`
   - `cd gui && npx tsc --noEmit && npm run test`
   - For a GUI change, also a real sanity check:
     `cd gui && npm run tauri dev` (confirm it compiles and launches;
     kill the `target/debug/gui`/`vite` processes afterward).
4. `git add <specific files>` (never `-A`/`.` - check `git status`
   first), commit with the session's Co-Authored-By/Claude-Session
   footer, `git push -u origin <branch>`.
5. `gh pr create` with a `## Summary` + `## Test plan` body.
6. **Wait for the user's explicit "merge" instruction before
   merging - even if CI is already green.** Watch with a polling
   loop: `while true; do out=$(gh pr checks <N> 2>&1); if ! echo
   "$out" | grep -q pending; then echo "$out"; break; fi; sleep 25;
   done` (via the Monitor tool, not blocking).
7. `gh pr merge <N> --squash --subject "..." --body-file -`.
8. `git checkout main && git pull --ff-only origin main`.
9. Delete the merged local branch (`git branch -D <branch>`) - verify
   it's actually merged first if unsure
   (`gh pr list --state merged --json headRefName,number,title`).

## Version bump (6 files, always together)

```sh
sed -i '' 's/BMU_VERSION="OLD"/BMU_VERSION="NEW"/' bin/backmeup.configure.sh
sed -i '' 's/"version": "OLD"/"version": "NEW"/' gui/package.json gui/src-tauri/tauri.conf.json
sed -i '' 's/"version": "OLD"/"version": "NEW"/g' gui/package-lock.json
sed -i '' 's/^version = "OLD"/version = "NEW"/' gui/src-tauri/Cargo.toml
sed -i '' 's/^version = "OLD"/version = "NEW"/' gui/src-tauri/Cargo.lock
```

Note: the Cargo files are under `gui/src-tauri/` - there is no root
`Cargo.lock`. `testGuiVersionStaysInSyncWithBmuVersion` in
`tests/test_backmeup.sh` catches any file left behind.

Goes out as its own `chore/version-X.Y.Z` branch/PR through the cycle
above - never bundled with other changes.

**Picking the next version** (full policy in `README.md`'s
"Versioning" section - this is just the mechanical reminder): odd
MINOR or PATCH = experimental (tag suffix `-experimental`,
`--prerelease`); even = tested (plain tag, no prerelease flag). PATCH
odd→even only needs CI green; **MINOR odd→even needs the user to
confirm they've actually installed and run a real build** - ask
explicitly, don't assume. Skipping straight from one odd number to
another (e.g. 2.18.1 → 2.18.3) is allowed and has been the normal
case so far - confirm the exact target version if the user doesn't
state one.

## Tag + release cycle (only when explicitly asked to "tag and release")

1. Confirm the current version first: `grep BMU_VERSION
   bin/backmeup.configure.sh`.
2. Do the version-bump branch/PR/merge cycle above.
3. `git checkout main && git pull --ff-only origin main`.
4. `git tag vX.Y.Z[-experimental] && git push origin vX.Y.Z[-experimental]`.
5. Find the triggered build: `gh run list --workflow=gui-release.yml --limit 2`.
6. Create the release immediately (don't wait for the build):
   `gh release create vX.Y.Z[-experimental] [--prerelease] --title
   "vX.Y.Z[-experimental]" --notes "..."` - end the notes with
   "Installers are attached once the build workflow finishes." as a
   placeholder.
7. Watch the build (Monitor + `gh run view <id> --json status -q
   '.status'`, polling).
8. Once it succeeds: `gh run download <id> --dir
   <scratchpad>/release-X.Y.Z`, then `gh release upload
   vX.Y.Z[-experimental] <the 3 downloaded files>` (macOS
   `.dmg`, Linux `.deb`, Linux `.AppImage`).
9. `gh release edit vX.Y.Z[-experimental] --notes "..."` to drop the
   placeholder line now that assets are attached.

## Safety boundaries (established this session - don't relitigate)

- **Never touch the user's real installed CLI** (`~/usr/bmu` or
  wherever their real `bin_dir` is) **or real backup data**
  (`~/Backups/...`) without being explicitly asked. All testing runs
  in sandboxes: `tests/test_backmeup.sh`'s own temp dirs, or ad hoc
  dirs under the scratchpad/`/tmp`.
- **Never merge a PR without the user explicitly saying so**, even
  once CI is green - report status and wait.
- **Write the test first, confirm it fails against the pre-fix
  code**, then implement (this project's own stated discipline, see
  `docs/CONTRIBUTING.md`). For a regression-guard test specifically,
  also confirm it actually catches the regression by temporarily
  reverting the fix and rerunning just that test.
- **Use Plan mode before implementing** a non-trivial or multi-file
  GUI change - this session consistently got better outcomes from
  planning first (e.g. the per-source status merge, the search
  freeze/pagination rework) than diving straight in.
- The GUI binary and the installed CLI scripts can drift out of sync
  (the GUI is often updated by installing a newer experimental
  release directly, ahead of the CLI). Any JSON field the Rust side
  adds to a struct the CLI produces must be `#[serde(default)]`,
  never required - see `parses_the_minimal_locate_json_contract_forever`
  in `gui/src-tauri/src/dashboard.rs` for the standing regression
  guard and why it exists.
